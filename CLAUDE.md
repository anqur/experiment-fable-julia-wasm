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
- **Rust `cargo test` is not wired yet.** Verify Rust changes via `cargo build`
  then run Julia-side tests.

## Build & test (native target)

**Use the dev profile (`cargo build`) for local development** — it keeps
Cranelift's `debug_assertions` ON (Cargo's dev-profile default; neither
`Cargo.toml` overrides `[profile.dev]`), which is how we catch IR-construction
bugs. Release (`cargo build --release`) is only for runtime-perf measurement
(`native-backend` sets `lto = true` + `opt-level = 3` in `[profile.release]`,
which is what makes it slow).

**The dev-profile gate must stay green.** It enforces two assertions the old
"transient `FunctionBuilder` per FFI call" pattern silently bypassed in release
(making debug builds panic). Both are now fixed by holding **one persistent
`FunctionBuilder` per function** in `FunctionCtx` (raw-pointer field, two-phase
init) and skipping redundant `switch_to_block` calls — see
`native-builder/src/builder.rs`. If a debug build panics again, that's a real
IR bug, not noise.

The Julia loader resolves the **debug artifact only** (`_debug_artifact` in
`NativeCodegen.jl`); `target/release` is never loaded during local development —
release carries no debug-assertions and a stale release build has shadowed a fresh
debug one, masking real bugs. Both `NativeCodegen.jl::_init_builder_lib` and
`builder_emit.jl::get_native_builder_lib` use it (the latter delegates to the
former). Release builds for perf measurement must be done out-of-band.

```bash
# Build Rust components (two crates) — DEV profile, fast local iteration
cd native-backend && cargo build && cd ..    # runtime static lib (.a)
cd native-builder && cargo build && cd ..    # eDSL builder (.so/dylib)
# (For optimized runtime perf only: add --release — expect ~1 min/crate.)

# Run eDSL pipeline test (43 tests)
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
| `native-backend/src/runtime/gc.rs` | Boehm GC (`bdwgc-alloc`), `GCHeader`, `__jl_gc_alloc`, `__jl_gc_alloc_array`, `__jl_gc_array_len`, `__jl_gc_type_tag`, `__jl_array_elem_ptr/get/set`, **`__jl_gc_alloc_julia`** (Julia-compatible struct/tuple alloc), **`__jl_array_new_1d`** (real `jl_alloc_array_1d` wrapper), **`__jl_array_grow_end`/`__jl_array_del_end`/`__jl_array_resize`** (real `jl_array_grow_end`/`del_end` wrappers for resize!) |
| `native-backend/src/runtime/strings.rs` | **`__jl_string_concat`** (real `jl_alloc_string` wrapper for `a*b`); legacy `__jl_string_new`/`_len`/`_get`/`_set` (old header — deprecated, not used for returnable strings) |

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
- ✅ Integer conversions (uextend, sextend, ireduce/trunc) — `(Type, value)` arg order
- ✅ Float↔int conversions (sitofp, uitofp, fptosi, fptoui, fpext, fptrunc) → Cranelift
  `fcvt_from_sint`/`fcvt_from_uint`/`fcvt_to_sint_sat`/`fcvt_to_uint_sat`/`fpromote`/`fdemote`.
  `fptosi`/`fptoui` use the **saturating** `_sat` variants (match Julia's unsafe_trunc latitude).
- ✅ Float math (sqrt_llvm, ceil_llvm, floor_llvm, trunc_llvm, rint_llvm, abs_float, copysign_float)
- ✅ Bit ops (ctlz/cttz/ctpop_int, bswap_int, flipsign_int, abs via flipsign_int(x,x))
  — **full-width (Int64/UInt64) correct; sub-word needs renormalization (NYI)**
- ✅ Control flow (GotoIfNot → brif, GotoNode → jump, ReturnNode → return)
- ✅ Phi nodes (block params + jump/brif args)
- ✅ Loops (while, gcd with swapping)
- ✅ SSA value tracking — `BuilderCtx` with `ssa_values`, `arg_values`
- ✅ `native_callable_from_so` — load compiled .so and call entry function
- ✅ String operations — read ops (ncodeunits, codeunit, sizeof, isempty) via direct
  load from String layout; **concatenation** (`a*b`, `a*b*c`, …) via `invoke Base._string`
  / `invoke *` → left-fold of `__jl_string_concat` (real `jl_alloc_string` String);
  **string-literal return** (`return "hi"`) via `pointer_from_objref` constant
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
- ✅ **Returning allocated objects to Julia** — mutable structs, tuples, AND fresh
  arrays (`Vector{T}`) round-trip through `unsafe_pointer_to_objref`. Structs/tuples
  use `__jl_gc_alloc_julia` (Julia-compatible `jl_value_t` header = type ptr + fields);
  arrays use Julia's own `jl_alloc_array_1d` (a *real* `jl_array_t`).
- ✅ Multi-field bitstype getfield with offset≠0 — shift/mask extraction
- ✅ Multi-element tuples — allocated via `__jl_gc_alloc_julia` with the real tuple
  type pointer; constant tuples in returns lower to `emit_core_tuple`
- ✅ Dynamic indexing of constant tuples (`getfield((1,2,3,4), i)`) — select chain
  (`block_add_select`); enables array literals `T[a,b,c,d]`
- ✅ Phi nodes with undef edges (loop-carried values on bounds-check escape paths)
  — zero-placeholder args keep jump arg counts aligned with block params
- ✅ `arraysize`/`size(arr, dim)` — via `getfield(getfield(arr, :size), dim)`
- ✅ **Array growth/shrink** — `resize!(a, n)` (grow + shrink) via
  `__jl_array_resize` → `jl_array_grow_end`/`jl_array_del_end`; **`push!(a, x)`**
  via `invoke Base._growend_internal!(a, 1, oldsize)` → `__jl_array_grow_end`;
  `memoryrefoffset` emitted as constant from `ref_tracking.byte_offset / elem_size + 1`.
- 🔄 **`pop!(a)` in progress** — `Core.memoryrefunset!` handler added (stores zero
  for GC safety); `Base.throw` emits trap; terminator-after-trap skipping added.
  Debug prints active in `emit_memoryrefnew`. Issue: returns `a[end-1]` instead of
  `a[end]` when combined with `resize!` — root cause under investigation (suspect
  cross-block SSA value resolution or block ordering).
- ⏸️ `append!` deferred (needs `invoke unsafe_copyto!` bulk copy between MemoryRefs).
- ✅ `compile_and_call` supports 0–2 args (was 0–1)

### Bridge type dispatch

`native_callable` dispatches on argument types with ccall (static types required):
- `_is_i64(T)`: `scalar_repr(T).bits == 64 && !isfloat`
- `_is_f64(T)`: `scalar_repr(T).isfloat && bits == 64`
- `_is_f32(T)`: `scalar_repr(T).isfloat && bits == 32`
- `_is_ptr_type(T)`: mutable struct, `String`, or `T <: Tuple` → passed/returned as
  `Ptr{Cvoid}` via `pointer_from_objref` (then `unsafe_pointer_to_objref` on return)
- Return types: `_call0()`/`_ret()` handle pointer (`unsafe_pointer_to_objref`),
  `Float64`/`Float32` (reinterpret), `Bool` (from_wire), and default `from_wire`
- `_norm_nargs(argtypes)`: treats a single `Tuple{}` argtype as "no arguments", so
  callers can pass `argtypes = Tuple{}` uniformly (matches `compile_and_call`)
- `compile_and_call(f, rettype, argtypes::Type{<:Tuple}, args...)`: one-shot helper
  supporting 0–2 args with automatic pointer↔object conversion (note: index arg
  types via `argtypes.parameters[i]`, NOT `argtypes[i]` — the latter is Julia's
  type-array literal syntax)
- Also `native_callable_from_so` for loading pre-linked .so files (bypasses Rust ccalls)

### Key eDSL conventions (builder_emit.jl ↔ native-builder)

- **Type enums** must match between Julia (`TYPE_I64=1`, `TYPE_I32=0`, `TYPE_F64=3`, etc.) and Rust
- **SSA tracking**: `BuilderCtx` tracks `ssa_values::Dict{Core.SSAValue, UInt32}`, `arg_values::Dict{Core.Argument, UInt32}`, `blocks::Dict{Int, String}`
- **Ref tracking**: `BuilderCtx.ref_tracking` maps SSA values → `(base_ptr_id, composed_offset, struct_type)` for non-loadable types like MemoryRef. When `getfield` encounters a type that `cranelift_type()` can't handle (e.g. MemoryRef is 16 bytes), it records the composed offset. Subsequent `getfield` on that SSA value uses the tracked offset to emit the real load.
- **FFI pattern**: Julia calls `ccall((:block_add_iadd, "libnative_builder"), ...)` with type enums and SSA IDs. The Rust side keeps **one persistent `FunctionBuilder` per function** in `FunctionCtx` (not one per FFI call); each `block_add_*` emits one instruction through it, skipping `switch_to_block` when already positioned on the target block. Holding one builder is mandatory — the old transient pattern tripped cranelift-frontend's `func_ctx.is_empty()` debug assertion.
- **Cranelift API**: `FunctionBuilder` in Rust. Methods: `create_block()`, `switch_to_block()`, `ins().iadd()`, `ins().iconst()`, `ins().return_()`, `seal_block()`, `finalize()`
- **Linking**: Julia's lld at `~/.julia/juliaup/julia-nightly/libexec/julia/lld`. Command: `lld -flavor ld.lld -shared -o out.so in.o libnative_backend.a`
- **Import declaration**: `builder_declare_import(name, ret_type, param_types)` → declares in ObjectModule with `Linkage::Import`. `block_add_call(name, args)` → emits `call` via `module.declare_func_in_func` + `fb.ins().call`.
- **Constant emission**: Each `resolve_operand` call for a constant emits a NEW iconst — constants are NOT cached across blocks, as that would cause Cranelift verifier cross-block dominance violations.
- **PIC required on ARM64 macOS**: The flags builder MUST set `is_pic = true` (requires `use cranelift_codegen::settings::Configurable`). Without PIC, external function calls crash with `ReadOnlyMemoryError` because ARM64 macOS enforces position-independent executables and `dyld` rejects absolute relocations in `.text`.
- **Conversion intrinsic arg order**: all conversions (`sext_int`/`zext_int`/`trunc_int`/`sitofp`/`uitofp`/`fptosi`/`fptoui`/`fpext`/`fptrunc`) are `(Type, value)` — args[1] is the *result* type, args[2] the value. The type arg can arrive as a bare `DataType`, a `Core.Const`/`QuoteNode`, OR a `GlobalRef` to the type (e.g. `GlobalRef(Base, Float64)`); `_unwrap_type` (`builder_emit.jl`) handles all three. Cranelift op mapping: int↔float via `fcvt_from_sint`/`fcvt_from_uint`/`fcvt_to_sint_sat`/`fcvt_to_uint_sat`; f32↔f64 via `fpromote`/`fdemote` (both take the result `Type`).
- **Intrinsic dispatch is dual**: intrinsics may arrive as `Core.IntrinsicFunction` (→ `emit_intrinsic`) OR as `GlobalRef` (`Base.sitofp`, `Base.bswap_int`, `Base.ceil_llvm`, … → `emit_globalref`). Each intrinsic must be handled in **both** places. Name via `ccall(:jl_intrinsic_name, …)` for the IntrinsicFunction form.
- **Bridge ABI gaps (FIXED)**: `native_callable[_from_so]` must ccall with the return type matching the function's actual return, and pass Float32 args via the Float32 ABI. `_call1_i64`/`_call1_i32` handle `Float64`/`Float32` returns (int-arg/float-return, e.g. `sitofp`); `_call1_f32` passes Float32 args (fpext). Float32 args are NOT lumped with Float64 (AArch64 `s0` ≠ `d0` — passing Float64 makes the callee read wrong bits).

### Known limitations & workarounds

1. **✅ RESOLVED: Allocated objects can be returned to Julia.** Mutable structs and
   tuples are allocated via `__jl_gc_alloc_julia(type_ptr, sizeof(T))` — a
   Julia-compatible `jl_value_t` (header = the datatype pointer, then fields at
   `fieldoffset`). Arrays are allocated via `__jl_array_new_1d(type_ptr, nel)`,
   which wraps Julia's own `jl_alloc_array_1d` so the result is a *real* GC-tracked
   `jl_array_t` (the fake `[type_ptr][len][data]` layout from `__jl_gc_alloc_array_julia`
   cannot match `jl_array_t` and would mis-index). `jl_alloc_array_1d` resolves
   against libjulia at `.so` load time. The `:new(Vector{T}, memref, (n,))` IR
   pattern is intercepted in `emit_new` (the memref arg is ignored; the real
   allocator determines layout). Element writes then flow through the existing
   `getfield(arr, :ref)`/`memoryrefset!` pipeline, exactly as for passed-in arrays.
   Note: `__jl_gc_alloc` / `__jl_gc_alloc_array` (legacy Boehm-header allocators)
   still exist but are NOT used for returnable objects.

2. **Cranelift ObjectModule `call` FIXED** — Added `is_pic = true` to the Cranelift
   flags builder and `use cranelift_codegen::settings::Configurable` import. On
   ARM64 macOS, PIC is mandatory — without it, absolute relocations (`ARM64_RELOC_UNSIGNED`)
   are emitted in the literal pool, which dyld refuses to write to read-only `.text`
   pages. With `is_pic = true`, Cranelift emits proper GOT-based access via
   `adrp` + `add` + `blr`, producing `ARM64_RELOC_GOT_LOAD_PAGE21` /
   `ARM64_RELOC_GOT_LOAD_PAGEOFF12` relocations.

3. **✅ RESOLVED: Bitstype multi-field structs** — `cranelift_type()` returns a
   scalar type by sizeof, but multi-field bitstypes now extract fields via
   shift/mask (`block_add_ushr` + `block_add_band`, sign-extend if signed).

4. **✅ RESOLVED: Multi-element tuples** — allocated via `__jl_gc_alloc_julia`
   with `pointer_from_objref(Tuple{types...})`; constant tuples in returns lower
   to `emit_core_tuple`. Tuples are treated as pointer types (`cranelift_type`,
   `_is_ptr_type`, `is_ptr_type` all special-case `T <: Tuple`).

5. **Julia nightly required** — `InferenceCache` is only in nightly.

6. **`native-backend` is `staticlib`** — produces `.a`. Do NOT change to
   `cdylib`; the linker embeds it into the final `.so`.

7. **CLIF text format is DEAD CODE**. The old `clif_emit.jl` has been removed.
   Do not add CLIF text generation — use the eDSL builder API instead.

8. **Unknown invoke sentinel** — unsupported `:invoke` calls emit constant 0
   instead of erroring. This allows functions with dead branches
   (e.g. bounds-check error paths) to compile. (Handled invokes: `ncodeunits`,
   `codeunit`, `sizeof`, `isempty`, and string concat `:*`/`Base._string`.)

9. **String ops — what's deferred** — String **read** ops + **concatenation** +
   **literal return** work. NOT yet supported: mixed-type `string(n)` (lowers to
   `invoke Base.print_to_string` / generated `Base.var"#string#N"` — needs
   integer-to-decimal formatting), `String(bytes::Vector{UInt8})` (lowers to
   `invoke WasmCodegen._memory_to_string` — needs Memory-pipeline data-ptr
   extraction), and string mutation / UTF-8 character indexing (byte/codeunit
   access works).

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
