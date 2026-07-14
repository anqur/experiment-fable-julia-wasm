# Julia → WasmGC + Native Codegen

Monorepo that compiles Julia through two targets:

- **Wasm:** `WasmTools` (binary format), `WasmtimeRunner` (wasmtime C API),
  `WasmCodegen` (IRCode → WasmGC), and `JSRuntime` (browser-runtime types).
- **Native:** `NativeCodegen` (Julia frontend → eDSL FFI), `native-builder`
  (Cranelift ObjectModule → `.o`), and `native-backend` (Rust runtime static
  library), linked by Julia's lld into a standalone `.so`.

**CLIF text is abandoned.** Native compilation exclusively uses Cranelift's
programmatic eDSL (`ObjectModule` and `FunctionBuilder`); never add CLIF
serialization or parsing.

## Environment

- Native codegen requires **Julia nightly** (`julia +nightly`): the shared
  WasmCodegen interpreter needs `Core.Compiler.InferenceCache`, which is absent
  from Julia 1.12 stable.
- `native-backend` requires Rust 1.80+.
- Set `export JULIA_DEPOT_PATH=$HOME/.julia`; `/workspace` does not exist on
  macOS and precompiled packages live in the home depot.
- Use the top-level dev environment: `julia +nightly --project=.`. Its
  `[sources]` entry develops all packages together.

## Milestone planning

Plan native milestones from **real compilation-gap analysis**, not a speculative
feature list. Run `NativeCodegen/test/debug_jlsyntax_probe.jl` (and related
probes) against JuliaSyntax.jl, a production parser distributed with Julia 1.14.

Record each `compile_native` result, group failures by root cause, then prioritize
by effort × number of unblocked functions. Probe representative bitwise predicates,
`Kind` construction, type predicates, field accessors, pointer loops, GreenNode
construction, varargs, and literal parsing dispatch. A compilation failure,
verifier failure, or bridge `MethodError` is a gap; a successful compilation is a
win.

## Rules — do not violate

### Tests and local development

- **Never use inline `julia -e` for exploratory tests.** Create descriptive `.jl`
  files under `NativeCodegen/test/` or `WasmCodegen/test/`. Permanent native tests
  belong in `test_edsl_approach.jl` or another `test_*.jl` file.
- Rust `cargo test` is not wired. Validate Rust changes with `cargo build`, then
  run the relevant Julia-side tests.
- Failed native tests must be **commented out** with `# TODO:` and their root
  cause. Never use `@test_skip`, or `try`/`catch` that disguises a known gap.
- Use the development profile (`cargo build`) locally. It preserves Cranelift
  debug assertions; a debug panic indicates a real IR-construction bug.
- Local Julia loading resolves only the debug artifact (`_debug_artifact` in
  `NativeCodegen.jl`). Never rely on a release artifact during development;
  release builds are for out-of-band runtime performance measurement only.

### Native architecture

- **No stubs, bridges, or host implementations.** Do not add import handlers,
  `@cfunction` wrappers, trampoline `.so` files, backend-library stubs, or any
  shortcut around the recursive native pipeline. Code must flow through
  IRCode → Cranelift IR → ObjectModule → `.o` → `.so`.
- **No import bridge for `parse!` or `ParseStream`.** They must compile through
  the recursive sentinel/worklist mechanism like every other `:invoke` callee.
- `native-backend` remains a Rust **`staticlib`**, embedded into the final `.so`.
  Do not change it to `cdylib`.

## Native architecture

```text
Julia source
  → WasmInterp (shared; do not rebuild)
  → optimized Julia IRCode (shared; do not rebuild)
  → NativeCodegen/builder_emit.jl
  → ccall → native-builder shared library
  → Cranelift ObjectModule → .o
  → Julia lld + libnative_backend.a → .so
  → Libdl/native callable
```

- **`native-builder`** (`cdylib`) owns Cranelift `ObjectModule` and
  `FunctionBuilder`, and exposes eDSL emission operations through FFI.
- **`native-backend`** (`staticlib`) supplies the pure-Rust GC, strings,
  exceptions, and arrays linked into the output.
- Output must not leave an undefined `jl_` symbol. `native-builder/src/linker.rs`
  checks this after linking; `nm -u out.so | grep jl_` must be empty. libc/libm
  symbols are legitimate unresolved host-process dependencies.

### Reused WasmCodegen pieces

Do not rebuild target-agnostic frontend facilities. `NativeCodegen.jl` imports:

| Facility | Source | Use |
|---|---|---|
| `WasmInterp` | `WasmCodegen/src/interp.jl` | Overlay `AbstractInterpreter` replacing pointer primitives with loop implementations |
| `ScalarRepr`, `_SCALAR_REPRS` | `WasmCodegen/src/reprs.jl` | Julia type → wire-width representation |
| `scalar_repr`, `isghost`, `ghost_instance` | `WasmCodegen/src/reprs.jl` | Representation/type queries |
| `from_wire`, `to_wire` | `WasmCodegen/src/reprs.jl` | Julia ↔ wire conversion |
| `CompileError` | `WasmCodegen/src/WasmCodegen.jl` | Unsupported-lowering error |
| `CC` | Julia compiler internals | `Core.Compiler` alias |

The shared `WASM_MT` overlay table also provides loop-based replacements for
pointer-dependent Base operations such as `codeunit`, `ncodeunits`, copying,
`fill!`, hash lookup, and `findnext`.

## Source layout

| Path | Role |
|---|---|
| `NativeCodegen/src/NativeCodegen.jl` | Module entry, compilation/linking entry points, callable ABI dispatch |
| `NativeCodegen/src/builder_emit.jl` | IRCode → eDSL emitter, SSA/control-flow/invoke/MemoryRef lowering |
| `NativeCodegen/src/clif_types.jl` | Native type-mapping helpers retained by the eDSL emitter |
| `NativeCodegen/src/interp.jl` / `reprs.jl` / `intrinsics.jl` | Intercepts, Wasm representation re-exports, intrinsic sets |
| `native-builder/src/builder.rs` | ObjectModule, persistent `FunctionBuilder`, instruction emission |
| `native-builder/src/lib.rs` / `linker.rs` | FFI entry points and Julia-lld linking/post-link checks |
| `native-builder/src/runtime.rs` | Builder-side runtime declarations |
| `native-backend/src/runtime/gc.rs` | Boehm allocation, Julia-compatible object/array helpers |
| `native-backend/src/runtime/strings.rs` | Pure-Rust string allocation and concatenation |

## Build and inspect

```bash
# Development profile only for routine work.
cd native-backend && cargo build && cd ..
cd native-builder && cargo build && cd ..

# Native eDSL regression suite.
julia +nightly --project=. NativeCodegen/test/test_edsl_approach.jl

# Read-only IR and real-world compilation-gap probes.
julia +nightly --project=. NativeCodegen/test/debug_array_ir.jl
julia +nightly --project=. NativeCodegen/test/debug_jlsyntax_probe.jl

# CLIF must not return.
find . -name "*.clif" -type f
```

The Wasm target uses `julia --project=.`, external validation from
`tools/wasm-tools-dist/wasm-tools`, and vendored wasmtime v45 C headers in
`tools/wasmtime-c-api/` for ABI probes.

## Julia object-layout notes

These are empirical layouts used for direct native memory access:

- `String`: length at `ptr + 0`; inline NUL-terminated bytes at `ptr + 8`.
- Mutable struct fields begin at `fieldoffset(T, field)` from
  `pointer_from_objref` (no GC header in that address).
- `Vector{Int64}`: `:ref` MemoryRef at offset 0 (16 bytes); `:size` tuple at
  offset 16 (8 bytes); total size 24 bytes.
- `MemoryRef{T}` and `Memory{T}` have three parameters; their element type is
  `parameters[2]`, not `parameters[1]`.
- Single-field bitstypes at offset zero pass through as their field. Multi-field
  bitstypes require width-aware shift/mask extraction or packing.

The runtime's externally visible layouts are Julia-compatible: strings are type
pointer + length + bytes; arrays are type pointer + `JuliaArrayRepr`; structs and
tuples are type pointer + fields. Internal temporary Memory objects may use the
legacy `GCHeader` layout and are never returned to Julia.

## Adding native features

1. Reuse a WasmCodegen facility if it already implements the target-independent
   part; do not duplicate it.
2. For IR lowering, add the handler in `builder_emit.jl` and the needed eDSL
   operation in `native-builder` (`builder.rs`, with an FFI wrapper in `lib.rs`).
3. For runtime support, add a `#[no_mangle] pub unsafe extern "C" fn` to
   `native-backend/src/runtime/`; link it statically, with no JIT registration.
4. For a genuinely new callable ABI type, extend the centralized bridge dispatch
   in `NativeCodegen.jl` and exercise it from a real native test file.

## eDSL invariants — critical

- **Keep one persistent `FunctionBuilder` per function.** `FunctionCtx` owns it
  through two-phase initialization; a transient builder per FFI operation masks
  or trips Cranelift debug assertions. Avoid redundant `switch_to_block` calls.
- Julia and Rust type enums must agree (`TYPE_I32=0`, `TYPE_I64=1`,
  `TYPE_F64=3`, etc.). `BuilderCtx` tracks `ssa_values`, `arg_values`, and
  blocks; `ref_tracking` preserves base pointer, composed offset, and type for
  non-loadable `MemoryRef`/`Memory` values.
- Emit a **fresh constant per block**. Caching an iconst across blocks violates
  Cranelift dominance rules.
- Sub-word values live in i32 registers and must be renormalized after arithmetic
  with `native_norm!`: sign-extend signed values; mask unsigned values. This is
  the renormalization referenced by `test_edsl_approach.jl`.
- All conversion intrinsics receive `(Type, value)`: argument 1 is the result
  type. `_unwrap_type` accepts a bare `DataType`, `Core.Const`/`QuoteNode`, or
  `GlobalRef`.
- Intrinsics arrive through **two paths**: `Core.IntrinsicFunction` goes through
  `emit_intrinsic`; `GlobalRef` goes through `emit_globalref`. Implement both.
  Use identity checks (`f === Core.Intrinsics.X`) before `jl_intrinsic_name` for
  intrinsics that Julia names `"invalid"`.
- Prefix entries with `__jl_entry_`. A bare entry named like a libcall (for
  example `ceil`) can bind the libcall to itself and recurse indefinitely.
- ARM64 macOS requires Cranelift PIC: set `is_pic = true` using
  `cranelift_codegen::settings::Configurable`.
- `_gcall` is the generated, arbitrary-arity callable dispatcher. It must issue
  **one** `ccall` per native invocation. Marshal mutable/reference-like objects
  by pointer; wrap immutable non-bitstype struct arguments in `Ref()` before
  `pointer_from_objref`.
- Julia FFI emission passes type enums and SSA ids. Rust emits instructions with
  the persistent builder. Linking uses Julia's lld:
  `lld -flavor ld.lld -shared -o out.so in.o libnative_backend.a`.
  Do not add `-lm` or `-lc`; Cranelift libcalls resolve against the host process.
- Checked arithmetic pairs are two SSA ids in `ssa_pairs[stmt_idx]`, read by
  `getfield(pair, 1/2)`, not allocated tuple objects. Block-sealing guards must
  avoid emitting an iconst or trap into an already-terminated block.

## Dispatch reference

- `:call` directly invokes intrinsics, GlobalRefs, or special forms such as
  `:boundscheck` and `:new`.
- `:invoke` is static dispatch through a `CodeInstance`/`MethodInstance`.
  The emitter follows that chain to identify overlay methods and lower them.

## Active limitations and diagnostic context

- Unknown `:invoke` calls currently emit a zero sentinel so dead error paths do
  not prevent surrounding code from compiling. Do not treat that as support for a
  live execution path.
- Deferred string work includes keyword-base formatting (`string(n, base=2)`),
  multi-argument formatting, `String(Vector{UInt8})`, mutation, and UTF-8
  character indexing. String reads, literals, and concatenation have dedicated
  lowering paths.
- **Recursive pipeline status:** `parse_into`/native `parse!` remains a
  compile-only case in `NativeCodegen/test/test_final.jl`. The recursive callees
  compile, but live parser execution can still miscompile because MemoryRef
  tracking degrades some array accesses to zero sentinels. Keep its runtime test
  commented with its `# TODO:` until it executes end-to-end.
- Some newly enabled `Union{Nothing,T}` return paths trigger Cranelift 0.133's
  `remove_constant_phis` abort (`entry_block()` missing during compilation).
  It cannot be caught because Cranelift aborts panics. Resolution options are a
  Cranelift upgrade or narrowly enabling only known-safe MethodInstances; do not
  broadly map those unions to `TYPE_I64` without reproducing and checking this.
- When rethrowing from emission, preserve a real terminator in the current block.
  Otherwise later block switching produces misleading invalid-block/no-terminator
  verifier errors; use `NCG_TRACE_RETHROW` to identify the original exception.

## Wasm conventions

- Correctness requires differential tests in `WasmCodegen/test/runtests.jl`
  (`@difftest` cases). Unsupported lowering must raise `CompileError`, never
  silently approximate behavior.
- `WasmTools` must satisfy byte-identical `encode(decode(bytes))` for binaries it
  produces.
- `Int8`/`Int16` and unsigned counterparts occupy i32; renormalize after
  arithmetic with the Wasm `emit_norm!` convention.
- WasmGC strings are `{bytes::(array mut i8)}` and use `__str_*` accessors.
  `JSRuntime.JSString` is an engine-resident `externref` lowered through
  `wasm:js-string` imports.
