# Julia → WasmGC + Native Codegen project

Monorepo of Julia packages and Rust crates for compiling Julia to both
WebAssembly-with-GC and native machine code (via Cranelift).

**Wasm target:** `WasmTools` (binary format), `WasmtimeRunner` (wasmtime C-API),
`WasmCodegen` (IRCode → wasm), `JSRuntime` (browser-runtime types).

**Native target:** `NativeCodegen` (Julia frontend → eDSL FFI), `native-builder`
(Rust eDSL + ObjectModule → .o), `native-backend` (Rust runtime static lib → .a),
linked by Julia's lld into a standalone `.so`. `examples/native_demo` (Rust consumer demo).

**Architecture change (Phase 2.2+): CLIF text format ABANDONED.** The pipeline
now uses Cranelift's programmatic eDSL API (`ObjectModule`, `FunctionBuilder`)
instead of serializing/parsing CLIF text.

## Environment

- **Julia nightly required** for native codegen (`julia +nightly`). The
  WasmCodegen overlay interpreter uses `Core.Compiler.InferenceCache` which
  was removed in Julia 1.12 stable but is available in nightly (1.14-DEV).
- **Rust 1.80+** for the `native-backend` crate.
- `export JULIA_DEPOT_PATH=$HOME/.julia` (the `/workspace` depot doesn't exist
  on macOS; precompiled packages live in `$HOME/.julia`).
- Top-level dev env: `julia +nightly --project=.` (devs all packages via
  `[sources]` in Project.toml).

### Testing rules

- **NEVER use inline `julia -e` for exploratory tests.** Always create real
  `.jl` test files under `NativeCodegen/test/` (or `WasmCodegen/test/` for
  wasm-specific work). Use descriptive names (e.g. `debug_struct_ir.jl`,
  `test_new_feature.jl`). Tests that are part of the permanent suite go in
  `test_edsl_approach.jl` or a new `test_*.jl` file.
- **Rust `cargo test` is not wired yet.** Verify Rust changes via
  `cargo build --release` then run Julia-side tests.

## Build & test (native target)

```bash
# Build Rust components (two crates)
cd native-backend && cargo build --release && cd ..    # runtime static lib (.a)
cd native-builder && cargo build --release && cd ..    # eDSL builder (.so/dylib)

# Run eDSL pipeline test (28 tests)
julia +nightly --project=. NativeCodegen/test/test_edsl_approach.jl

# Explore IR patterns (read-only inspection)
julia +nightly --project=. NativeCodegen/test/debug_array_ir.jl

# Verify no CLIF serialization (should be empty)
find . -name "*.clif" -type f
```

## Wasm target (existing)

- `julia --project=.` (no nightly needed)
- External validator: `tools/wasm-tools-dist/wasm-tools`
- Vendored wasmtime C API: `tools/wasmtime-c-api/` (v45.0.1)

## Native codegen architecture (eDSL — current)

**CLIF text format has been ABANDONED (Phase 2.2).** The pipeline now uses
Cranelift's programmatic eDSL API. There is NO IR serialization/parsing.

```
Julia source
  → WasmInterp (reused from WasmCodegen) ← DO NOT REBUILD
  → Julia IRCode (optimized SSA)         ← DO NOT REBUILD
  → builder_emit.jl (eDSL FFI emitter)   ← CURRENT
  → ccall → native-builder.so (Rust)     ← CURRENT
  → Cranelift ObjectModule → .o file
  → lld linker + libnative_backend.a → .so
  → Julia callable via Libdl
```

Two Rust crates:
- **`native-builder`** (`cdylib`): eDSL builder. Uses Cranelift `ObjectModule` +
  `FunctionBuilder` API. Produces `.o` files programmatically. Called via FFI
  from `builder_emit.jl`.
- **`native-backend`** (`staticlib`): Runtime only — Boehm GC, string ops,
  exception handling, arrays. Linked into the final `.so` by Julia's lld.

### What's reused from WasmCodegen (do NOT rebuild)

These are imported via `using WasmCodegen` / `const X = WasmCodegen.X` at the top
of `NativeCodegen.jl`. They are target-agnostic and work identically for native:

| Import | Source file | Purpose |
|--------|-------------|---------|
| `WasmInterp` | `WasmCodegen/src/interp.jl` | Custom `AbstractInterpreter` with overlay method table that replaces pointer-based Base primitives (memcpy, memchr, utf8proc) with loop-based equivalents before inlining |
| `ScalarRepr`, `_SCALAR_REPRS` | `WasmCodegen/src/reprs.jl` | Mapping Julia types → wire-width representations |
| `scalar_repr(T)`, `isghost(T)`, `ghost_instance` | `WasmCodegen/src/reprs.jl` | Type queries |
| `from_wire(T, v)`, `to_wire(T, v)` | `WasmCodegen/src/reprs.jl` | Julia ↔ wire format conversion |
| `CompileError` | `WasmCodegen/src/WasmCodegen.jl` | Exception type for unsupported constructs |
| `INTERCEPTS`, `EXTERNREF_TYPES` | `WasmCodegen/src/interp.jl` | Interception registry |
| `CC` (= `Core.Compiler`) | | Julia's compiler internals |

The overlay method table (`WASM_MT`) is also shared — stubs that replace
`codeunit`, `ncodeunits`, `unsafe_copyto!`, `fill!`, `ht_keyindex`, `findnext`,
etc. with loop-based equivalents.

### Current file layout (native target)

| File | Role |
|------|------|
| `NativeCodegen/src/NativeCodegen.jl` | Module entry, WasmCodegen imports, bridge: `compile_native`, `native_callable`, `native_callable_from_so`. Arg/return type dispatch for ccall. |
| `NativeCodegen/src/builder_emit.jl` | **eDSL emitter.** SSA tracking via `BuilderCtx`, type enum mapping, FFI calls to `native-builder`. Handles: intrinsics, GlobalRef calls, invoke, control flow, struct getfield/setfield!, pointer ops, MemoryRef pipeline, PiNode, boundscheck, new/memorynew (stubs). |
| `NativeCodegen/src/clif_types.jl` | Type mapping helpers (still used by builder_emit.jl) |
| `NativeCodegen/src/interp.jl` | Thin wrapper: `NATIVE_INTERCEPTS` registry |
| `NativeCodegen/src/reprs.jl` | Re-exports WasmCodegen reprs |
| `NativeCodegen/src/intrinsics.jl` | Declares `STRING_INTRINSICS` and `ARRAY_INTRINSICS` sets |
| `native-builder/src/builder.rs` | Cranelift ObjectModule + FunctionBuilder. `FunctionCtx` with full instruction emission: arithmetic, comparisons, bitwise, float, conversions, load/store, control flow (jump/brif/return/trap), call imports. `BuilderContext` with import registry. |
| `native-builder/src/linker.rs` | Invokes Julia's lld: `lld -flavor ld.lld -shared -o out.so in.o libnative_backend.a` |
| `native-builder/src/lib.rs` | FFI entry points: `create_builder`, `builder_add_function`, `builder_declare_import`, all `block_add_*` instruction emitters, `builder_finalize`, `link_object_to_so`. |
| `native-builder/src/runtime.rs` | Runtime stubs (linked via native-backend.a) |
| `native-backend/src/runtime/gc.rs` | Boehm GC (`bdwgc-alloc`), `GCHeader`, `__jl_gc_alloc`, `__jl_gc_alloc_array`, `__jl_gc_array_len`, `__jl_gc_type_tag`, `__jl_array_elem_ptr/get/set` |

### Key Julia object layouts (known from empirical exploration)

These layouts are derived from `pointer_from_objref` and used by the eDSL emitter
for direct memory access (no runtime calls needed):

- **String**: `ptr + 0` → length (::Int64), `ptr + 8` → inline char data (null-terminated)
- **Mutable struct**: `fieldoffset(T, :field)` starts at 0 from `pointer_from_objref` (no GC header)
- **Vector{Int64}**: `:ref` at offset 0 (MemoryRef, 16 bytes), `:size` at offset 16 (Tuple{Int64}, 8 bytes), total sizeof = 24
- **MemoryRef{T}**: type has 3 params `(:not_atomic, T, Core.AddrSpace)` — element type T is at `parameters[2]` (NOT `parameters[1]`)
- **Memory{T}**: Same 3-param structure as MemoryRef
- **Bitstype fields**: For single-field bitstypes at fieldoffset 0, the value IS the field (pass through). Multi-field bitstypes need shift/extract — NYI.

### How to add a new feature (current pipeline)

1. **If WasmCodegen already handles it**: just use the import — don't reimplement.
2. **If it needs IR → Cranelift emission**: add handler in `builder_emit.jl`
   (Julia side) and wire in `native-builder/src/builder.rs` (Rust side). Use
   Cranelift `FunctionBuilder` methods: `ins().iadd()`, `ins().iconst()`,
   `ins().return_()`, `create_block()`, `switch_to_block()`, `seal_block()`.
   For new FFI ops: add `ffi_binop!`/`ffi_unop!`/`ffi_convert!` macro in
   `lib.rs` or write a custom `#[no_mangle]` wrapper.
3. **If it needs runtime support**: add `#[no_mangle] pub unsafe extern "C" fn`
   in `native-backend/src/runtime/`. No JIT symbol registration needed — the
   runtime is linked statically.
4. **If it needs bridge support** (new arg/return types): add `_call*` variant
   in `NativeCodegen.jl` and wire it in `native_callable`'s type dispatch.

### Implementation status

- ✅ Scalar arithmetic (iadd, isub, imul, sdiv, udiv, srem, urem, neg, not)
- ✅ Scalar comparisons (icmp eq/ne/slt/sle/ult/ule; fcmp)
- ✅ Bitwise ops (band, bor, bxor, ishl, ushr, sshr)
- ✅ Float ops (fadd, fsub, fmul, fdiv, fneg)
- ✅ Integer conversions (uextend, sextend, ireduce/trunc)
- ✅ Control flow (GotoIfNot → brif, GotoNode → jump, ReturnNode → return)
- ✅ Phi nodes (block params + jump/brif args)
- ✅ Loops (while, gcd with swapping)
- ✅ SSA value tracking — `BuilderCtx` with `ssa_values`, `arg_values`
- ✅ `native_callable_from_so` — load compiled .so and call entry function
- ✅ String operations — ncodeunits, codeunit, sizeof, isempty (via direct load from String layout)
- ✅ Mutable struct getfield/setfield! — load/store at `fieldoffset` (nested access works)
- ✅ Array length — `length(a)` via bitstype getfield from Vector layout
- ✅ Array element read/write — pointerref/pointerset (unsafe_load/store)
- ✅ Bounds-checked array access — memoryrefnew/memoryrefget/memoryrefset pipeline (@inbounds)
- ✅ PiNode passthrough, boundscheck emission, union-return traps
- ✅ eDSL builder infrastructure — ObjectModule, FunctionBuilder, lld linker
- ✅ `BuilderContext` owns `ObjectModule` from `new()` with import registry
- ✅ Platform-appropriate calling convention (`AppleAarch64` on ARM64 macOS)
- ✅ Runtime GC functions: `__jl_gc_alloc`, `__jl_gc_alloc_array`, array helpers
- ✅ Struct allocation (`:new`) — works for internal use within compiled functions
- ✅ Array allocation (`:memorynew`) — works for internal use within compiled functions
- 🚧 Returning allocated objects to Julia — Boehm-GC-allocated memory lacks Julia object headers
- 🚧 Bitstype struct getfield with offset≠0 — NYI (need shift/extract)
- 🚧 Multi-element tuples — NYI (single-element passes through)

### Bridge type dispatch

`native_callable` dispatches on argument types with ccall (static types required):
- `_is_i64(T)`: `scalar_repr(T).bits == 64 && !isfloat`
- `_is_f64(T)`: `scalar_repr(T).isfloat && bits == 64`
- `_is_f32(T)`: `scalar_repr(T).isfloat && bits == 32`
- `_is_ptr_type(T)`: mutable struct → passed as `Ptr{Cvoid}` via `pointer_from_objref`
- Return types: `_ret()` handles `Float64` (reinterpret), `Float32` (reinterpret),
  `Bool` (from_wire), `Ptr{Cvoid}`, and default `from_wire`
- Also `native_callable_from_so` for loading pre-linked .so files (bypasses Rust ccalls)

### Key eDSL conventions (builder_emit.jl ↔ native-builder)

- **Type enums** must match between Julia (`TYPE_I64=1`, `TYPE_I32=0`, `TYPE_F64=3`, etc.) and Rust
- **SSA tracking**: `BuilderCtx` tracks `ssa_values::Dict{Core.SSAValue, UInt32}`, `arg_values::Dict{Core.Argument, UInt32}`, `blocks::Dict{Int, String}`
- **Ref tracking**: `BuilderCtx.ref_tracking` maps SSA values → `(base_ptr_id, composed_offset, struct_type)` for non-loadable types like MemoryRef. When `getfield` encounters a type that `cranelift_type()` can't handle (e.g. MemoryRef is 16 bytes), it records the composed offset. Subsequent `getfield` on that SSA value uses the tracked offset to emit the real load.
- **FFI pattern**: Julia calls `ccall((:block_add_iadd, "libnative_builder"), ...)` with type enums and SSA IDs. Each FFI call creates a transient `FunctionBuilder`, emits one instruction, then drops it.
- **Cranelift API**: `FunctionBuilder` in Rust. Methods: `create_block()`, `switch_to_block()`, `ins().iadd()`, `ins().iconst()`, `ins().return_()`, `seal_block()`, `finalize()`
- **Linking**: Julia's lld at `~/.julia/juliaup/julia-nightly/libexec/julia/lld`. Command: `lld -flavor ld.lld -shared -o out.so in.o libnative_backend.a`
- **Import declaration**: `builder_declare_import(name, ret_type, param_types)` → declares in ObjectModule with `Linkage::Import`. `block_add_call(name, args)` → emits `call` via `module.declare_func_in_func` + `fb.ins().call`.
- **Constant emission**: Each `resolve_operand` call for a constant emits a NEW iconst — constants are NOT cached across blocks, as that would cause Cranelift verifier cross-block dominance violations.
- **PIC required on ARM64 macOS**: The flags builder MUST set `is_pic = true` (requires `use cranelift_codegen::settings::Configurable`). Without PIC, external function calls crash with `ReadOnlyMemoryError` because ARM64 macOS enforces position-independent executables and `dyld` rejects absolute relocations in `.text`.

### Known limitations & workarounds

1. **Cranelift ObjectModule `call` FIXED** — Added `is_pic = true` to the Cranelift
   flags builder and `use cranelift_codegen::settings::Configurable` import. On
   ARM64 macOS, PIC is mandatory — without it, absolute relocations (`ARM64_RELOC_UNSIGNED`)
   are emitted in the literal pool, which dyld refuses to write to read-only `.text`
   pages. With `is_pic = true`, Cranelift emits proper GOT-based access via
   `adrp` + `add` + `blr`, producing `ARM64_RELOC_GOT_LOAD_PAGE21` /
   `ARM64_RELOC_GOT_LOAD_PAGEOFF12` relocations. Also tried `Linkage::Preemptible`
   but `Linkage::Import` works fine with PIC enabled.

2. **Allocated objects can't be returned to Julia** — `emit_new` and `emit_memorynew`
   call `__jl_gc_alloc` / `__jl_gc_alloc_array` via the now-fixed call mechanism.
   Allocation, field stores, and field loads all work correctly within compiled
   functions. However, the returned pointer **cannot** be passed to Julia's
   `unsafe_pointer_to_objref` — it crashes with:
   ```
   signal 11: Segmentation fault
   typekeyvalue_hash → lookup_typevalue → lookup_arg_type_tuple → jl_lookup_generic_
   ```
   **Why**: `__jl_gc_alloc` allocates via Boehm GC (`bdwgc-alloc`) with a custom
   `GCHeader { type_tag, flags, length }` prepended. Julia's `unsafe_pointer_to_objref`
   expects the pointer to point to a `jl_value_t` with Julia's internal type tag
   (a `jl_datatype_t*`). Boehm's header has no Julia type tag, so Julia's type
   system dereferences garbage and crashes in `typekeyvalue_hash`.
   
   **Verified working**: raw `ccall` returns a valid non-null pointer; storing and
   loading fields at `fieldoffset` offsets works correctly.
   
   **Workaround**: Pre-allocate mutable structs/arrays in Julia, pass them as
   `Ptr{Cvoid}` arguments to compiled functions, use `getfield`/`setfield!` or
   pointer ops to read/write. This is how all 28 existing tests work.

3. **Bitstype multi-field structs** — `cranelift_type()` returns a scalar type by
   sizeof, but multi-field bitstypes need field extraction (ireduce/ishift).
   Currently only single-field bitstypes at offset 0 work (value IS the field).

4. **Julia nightly required** — `InferenceCache` is only in nightly.

5. **`native-backend` is `staticlib`** — produces `.a`. Do NOT change to
   `cdylib`; the linker embeds it into the final `.so`.

6. **CLIF text format is DEAD CODE**. The old `clif_emit.jl` has been removed.
   Do not add CLIF text generation — use the eDSL builder API instead.

7. **Unknown invoke sentinel** — unsupported `:invoke` calls emit constant 0
   instead of erroring. This allows functions with dead branches
   (e.g. bounds-check error paths) to compile.

### Invoke vs Call dispatch

Julia IR uses two expression heads for function calls:

- **`:call`** — direct calls to intrinsics (`Core.IntrinsicFunction`), GlobalRefs
  (top-level functions like `+`, `getfield`, `Core.sizeof`, `pointerref`), and
  a few special forms (`:boundscheck`, `:new`).
- **`:invoke`** — static dispatch through `MethodInstance`/`CodeInstance`. Used
  for overlay methods (e.g. `Base.ncodeunits`, `Base.codeunit`, `Base.isempty`)
  and other specialized method calls.

The overlay method table replaces pointer-based Base primitives with loop-based
equivalents. The invoke handler in `builder_emit.jl` navigates
`CodeInstance → MethodInstance → Method` to find the method name and dispatches
to the appropriate emitter.

## Wasm conventions (existing)

- Correctness bar: *differential testing*. Any codegen change needs corpus
  entries in `WasmCodegen/test/runtests.jl` (`@difftest f Tuple{...} cases`).
- Loud failure beats silent miscompilation: throw `CompileError`, never emit
  approximate code.
- `WasmTools` invariant: `encode(decode(bytes))` byte-identical for self-produced
  binaries.
- Sub-word integers (Int8/16, UInt8/16) live in i32 with sign/zero extension;
  renormalize after arithmetic (`emit_norm!`).
- `String` is wasm-GC-resident: `{bytes::(array mut i8)}` struct. Hosts use
  `__str_new/__str_set/__str_len/__str_get` accessors.
- `JSRuntime.JSString` is engine-resident (`externref`); ops lower to
  `"wasm:js-string"` imports.
