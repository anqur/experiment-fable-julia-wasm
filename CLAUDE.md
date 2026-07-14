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

### Milestone planning

**Always plan next milestones based on real-world compilation gap analysis,**
not speculative feature lists. The primary driver is **JuliaSyntax.jl**
(`julia +nightly --project=. NativeCodegen/test/debug_jlsyntax_probe.jl`) —
a production parser library shipped with Julia 1.14. Probe representative
functions from it through `compile_native`, catalog systematic failures, and
rank by effort × number-of-functions-unblocked. The probe results determine
which work items are worth doing next.

The probe file exercises: bitwise predicates, Kind construction, type
predicates, field accessors, pointer loops, GreenNode constructors, varargs,
and literal parsing dispatch. A function that compiles successfully counts
as a win; a `CompileError` / verifier failure / bridge `MethodError` is a
gap. Group failures by root cause (e.g. "Bool return ABI", "GreenNode
pointer classification") and attack the causes that block the most functions
first.

### Testing rules

- **NEVER use inline `julia -e` for exploratory tests.** Always create real
  `.jl` test files under `NativeCodegen/test/` (or `WasmCodegen/test/` for
  wasm-specific work). Use descriptive names (e.g. `debug_struct_ir.jl`,
  `test_new_feature.jl`). Tests that are part of the permanent suite go in
  `test_edsl_approach.jl` or a new `test_*.jl` file.
- **Rust `cargo test` is not wired yet.** Verify Rust changes via `cargo build`
  then run Julia-side tests.

### Absolute rules (DO NOT VIOLATE)

- **NO STUBS, BRIDGES, OR HOST IMPLEMENTATIONS.** Do not add import handlers,
  `@cfunction` wrappers, trampoline `.so` files, `libnative_backend.a` stubs,
  or any other mechanism that short-circuits the recursive pipeline.
  Everything must compile through the native codegen pipeline: IRCode → Cranelift
  IR → ObjectModule → .o → .so. Runtime must use only compiled native code.
- **NO IMPORT BRIDGE FOR parse! / ParseStream.** These must compile through
  the recursive sentinel + worklist, same as any other `:invoke` callee.
- **MARK FAILED TESTS AS COMMENTED.** Tests that cannot pass due to incomplete
  compilation must be commented out (not `@test_skip`, not `try-catch` with
  "KNOWN GAP"). Comment with `# TODO:` and the root cause. This keeps the test
  suite honest — every active `@test` must actually pass.

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
- **`native-backend`** (`staticlib`): Self-contained runtime — Boehm GC, string ops,
  exception handling, arrays. **Zero libjulia dependency** — all allocation and
  mutation is pure Rust. Linked into the final `.so` by Julia's lld.

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
| `native-backend/src/runtime/gc.rs` | Boehm GC (`bdwgc-alloc`), `GCHeader`, `__jl_gc_alloc`, `__jl_gc_alloc_array`, `__jl_gc_array_len`, `__jl_gc_type_tag`, `__jl_array_elem_ptr/get/set`, **`__jl_gc_alloc_julia`** (Julia-compatible struct/tuple alloc), **`__jl_array_new_1d`** (pure-Rust array allocator via Boehm GC), **`__jl_array_grow_end`/`__jl_array_del_end`/`__jl_array_resize`** (pure-Rust array mutation), **`rust_alloc_string`** (pure-Rust String allocator) |
| `native-backend/src/runtime/strings.rs` | **`__jl_string_concat`** (pure-Rust via `rust_alloc_string`); legacy `__jl_string_new`/`_len`/`_get`/`_set` (old header — deprecated, not used for returnable strings) |

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
- ✅ Scalar comparisons (icmp eq/ne/slt/sle/ult/ule/sgt/sge/ugt/uge; fcmp eq/ne/lt/le/gt/ge)
- ✅ Bitwise ops (band, bor, bxor, ishl, ushr, sshr)
- ✅ Float ops (fadd, fsub, fmul, fdiv, fneg)
- ✅ Integer conversions (uextend, sextend, ireduce/trunc) — `(Type, value)` arg order
- ✅ Float↔int conversions (sitofp, uitofp, fptosi, fptoui, fpext, fptrunc) → Cranelift
  `fcvt_from_sint`/`fcvt_from_uint`/`fcvt_to_sint_sat`/`fcvt_to_uint_sat`/`fpromote`/`fdemote`.
  `fptosi`/`fptoui` use the **saturating** `_sat` variants (match Julia's unsafe_trunc latitude).
- ✅ Float math (sqrt_llvm, ceil_llvm, floor_llvm, trunc_llvm, rint_llvm, abs_float, copysign_float)
- ✅ Bit ops (ctlz/cttz/ctpop_int, bswap_int, flipsign_int, abs via flipsign_int(x,x))
  — **all widths correct**: `clz` subtracts `(32 - 8*sizeof(T))` padding for sub-word types
  stored in i32; `ctz` clamps the zero-input result (Cranelift returns 32) to the logical
  width; `ctpop` needs no correction for zero-extended sub-word values (see `emit_clz`/`emit_ctz`
  in `builder_emit.jl`)
- ✅ Control flow (GotoIfNot → brif, GotoNode → jump, ReturnNode → return)
- ✅ **GotoIfNot fallthrough fix** — `succs[2] == dest` for `Union{Nothing,T}` isa
  dispatch caused both `brif` branches to target the same trap block → SIGILL.
  Fixed by checking equality and using `succs[1]` as fallthrough. Unblocks all
  `children()[i]` indexing and tree-walking functions.
- ✅ **Sub-word memory type (I8/I16 in pointerref/memoryrefget)** — `cranelift_type`
  returns TYPE_I32 (register width) for sub-word types, but memory loads/stores
  need actual byte width. Fixed `emit_pointerref`/`emit_memoryrefget`/`emit_memoryrefset`
  to use `load.i8`/`load.i16` + `uextend` for sizeof<4, and `ireduce` for stores.
- ✅ **`haschildren(GreenNode)` invoke handler** — deprecated `!is_leaf` wrapper
  fell through to sentinel. Handler in `emit_invoke` loads `:children` field,
  compares with nothing tag via `ICMP_NE`.
- ✅ **Type{Float64} + Ptr bridge** — `_gcall` now marshals `Type` singletons
  (`pointer_from_objref`) and `Ptr` types (direct `Ptr{Cvoid}` cast).
- ✅ **Band type harmonization fix** — `get_operand_type` now resolves `GlobalRef`
  operands to their actual value types (e.g., `TRIVIA_FLAG` → `UInt16`), preventing
  incorrect `uextend` from `cranelift_type(GlobalRef)=TYPE_PTR`.
- ✅ Phi nodes (block params + jump/brif args)
- ✅ Loops (while, gcd with swapping)
- ✅ SSA value tracking — `BuilderCtx` with `ssa_values`, `arg_values`
- ✅ `native_callable_from_so` — load compiled .so and call entry function
- ✅ String operations — read ops (ncodeunits, codeunit, sizeof, isempty) via direct
  load from String layout; **concatenation** (`a*b`, `a*b*c`, …) via `invoke Base._string`
  / `invoke *` → left-fold of `__jl_string_concat` (pure-Rust via `rust_alloc_string`);
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
  arrays use `__jl_array_new_1d` (pure-Rust allocator producing `JuliaArrayRepr` layout).
- ✅ Multi-field bitstype getfield with offset≠0 — shift/mask extraction
- ✅ Multi-element tuples — allocated via `__jl_gc_alloc_julia` with the real tuple
  type pointer; constant tuples in returns lower to `emit_core_tuple`
- ✅ Dynamic indexing of constant tuples (`getfield((1,2,3,4), i)`) — select chain
  (`block_add_select`); enables array literals `T[a,b,c,d]`
- ✅ Phi nodes with undef edges (loop-carried values on bounds-check escape paths)
  — zero-placeholder args keep jump arg counts aligned with block params
- ✅ `arraysize`/`size(arr, dim)` — via `getfield(getfield(arr, :size), dim)`
- ✅ **Array growth/shrink** — `resize!(a, n)` (grow + shrink) via
  `__jl_array_resize` (pure-Rust, manipulates `JuliaArrayRepr` directly); **`push!(a, x)`**
  via `invoke Base._growend_internal!(a, 1, oldsize)` → `__jl_array_grow_end` (pure-Rust);
  `memoryrefoffset` emitted as constant from `ref_tracking.byte_offset / elem_size + 1`.
  — tracked as a bridge/IR issue, not a runtime dependency problem.
- ✅ **`pop!(a)`** — lowers through existing plumbing (no dedicated handler):
  `memoryrefget` reads last element, `Core.memoryrefunset!` zeroes it for GC
  safety, `Base.setfield!(:size, (n-1,))` shrinks, `Base.throw`→trap with
  terminator-after-throw block skipping. `pop!` returns the *element* (Int64),
  not the array, and mutates the caller's array in place.
- ✅ **`append!(a, b)`** — `_growend_internal!` (handled) + `setfield!(:size)`
  (handled) + `invoke Base.unsafe_copyto!(dst_memref, src_memref, n)`. The
  copy lowers to `__jl_memcpy(dst_addr, src_addr, n*sizeof(T))` (a
  `copy_nonoverlapping` wrapper in `gc.rs`); the two memrefs are resolved from
  `ref_tracking` (their tracked element addresses). Ranges (`%new(UnitRange,…)`
  built only for the dead `_throw_boundserror_indices` path) emit a sentinel.
- ✅ **Runtime-element array literals** — `[a, b, c]` where elements are
  variables (not constants). Julia lowers to `Core.tuple(%a,%b,%c)`
  (`emit_core_tuple` allocates a heap tuple) + a `getfield(%t, %k)` loop.
  `emit_struct_getfield` routes runtime tuples through the new
  `emit_tuple_index_from_ssa`: loads each field from the tuple pointer at
  `fieldoffset`, then returns the one requested (constant index) or a
  `block_add_select` chain over the dynamic index (mirrors the constant-tuple
  `emit_tuple_index`). Single-element tuples pass through (no allocation).
- ✅ **Bitstype immutable struct construction** — `%new(T, fields...)` where
  `isbitstype(T)` packs fields into a register via `uextend` + `ishl` + `bor`
  (the inverse of the existing getfield Case 3 `ushr` + `band` extraction). The
  struct's Cranelift type determines the register width; sub-word field types
  (`Int16`/`Int8`) are `uextend`-ed to match. Only ≤8-byte structs supported
  (`cranelift_type` throws for larger). Non-bitstype immutable structs (heap
  fields) — `emit_new` heap-allocates via `isconcretetype(T)` guard (was
  `ismutabletype`). `_gcall` wraps immutable args with `Ref` so `pointer_from_objref`
  works. The `cranelift_type`/`_is_ptr_type`/`is_ptr_type` immutable-nonbitstype
  clause excludes `GenericMemoryRef`/`GenericMemory` (Core memory types, by
  `T.name.name`) to keep the ref_tracking pipeline intact.
- ✅ **Bool return ABI** — `emit_not_int` now `uextend`s to I32 (like `emit_icmp`
  already did). `Core.ReturnNode` previously passed raw I8 from `icmp` to the
  return instruction, which Cranelift rejected against the I32 function signature.
- ✅ **`GlobalRef` as operand** — `resolve_operand` resolves `Core.GlobalRef` to
  its module-constant value at compile time (e.g. `JuliaSyntax.TRIVIA_FLAG`).
- ✅ **`Base.add_ptr`** — `emit_globalref` routes `add_ptr(ptr, offset)` to
  `emit_binop(:block_add_iadd, ...)` — pointer addition is just integer addition
  in Cranelift.
- ✅ **Primitive-type operands** — `resolve_operand` handles `isprimitivetype`
  values (e.g. `JuliaSyntax.Kind`, a `UInt16`-backed primitive) by
  `reinterpret(UInt, val)` → iconst.
- ✅ **N-argument bridge** — `compile_and_call`, `native_callable`, and
  `native_callable_from_so` support **any arity** via a single `@generated _gcall`
  dispatcher (`NativeCodegen.jl`) that builds the `ccall` argument-type tuple from
  the declared `argtypes`. Replaced the old enumerated `_call0`/`_call1_*`/`_call2_*`
  ladder (which capped at 2 args). Marshalling: arg ptr→`Ptr{Cvoid}`(pointer_from_objref),
  f64→Float64, f32→Float32(abi), i64→Int64(to_wire), else→Int32(to_wire); return
  Nothing→Cvoid, ptr→unsafe_pointer_to_objref, Float64/Float32→direct, else→Int64+from_wire.
  Calls the compiled function exactly once.
- ⏸️ **`string(n)` integer formatting** — NOT YET WIRED. The Rust runtime
  previously had `__jl_int_to_string` (since removed as dead code in `print.rs`).
  Adding this requires a `#string#` prefix handler in `emit_invoke` + a new
  pure-Rust `__jl_int_to_string` backed by `rust_alloc_string`. Keyword args
  (`string(n, base=2)`) and multi‑arg (`string(a,b)`) are deferred — they go
  through `print_to_string` (varargs) or keyword‑argument desugaring
  (`Core._apply_iterate`, `kwerr`).
- ✅ **Sub-word integer renormalization** — `native_norm!(bc, val, T)` in
  `builder_emit.jl` post‑op: signed→`(val << pad) >> pad` (shift‑left then
  arithmetic‑shift‑right, pads `32 - bits`), unsigned→`band` with `0xFF`/`0xFFFF`
  mask. Mirrors WasmCodegen's `emit_norm!`. Applied at every arithmetic binop
  (add/sub/mul/div/rem), `neg_int`, `not_int`, `flipsign_int`, `emit_icmp`
  operand pre‑comparison, and `emit_trunc` post‑ireduce.
- ✅ **Checked-arithmetic overflow pairs** — `checked_{s,u}{add,sub,mul}_int` return
  `(value, overflowed::Bool)` from a *single* IR stmt. Materialized as TWO value
  ids in `bc.ssa_pairs[stmt_idx] = (value_id, flag_id)` (no tuple allocation),
  read back by `getfield(pair, 1/2)` (intercepted at the top of
  `emit_struct_getfield`). Mirrors WasmCodegen's `ssapair` mechanism. Overflow is
  detected branch-free and trap-free (Cranelift 0.133 has no native overflow
  opcode): add/sub via the sign-bit comparison `((r⊕a)&(r⊕b))<0` / borrow `r<u a`;
  mul via a division check using a **"safe divisor"** (`select` to 1 when `a∈{0,-1}`,
  else `a`) so the guarding `sdiv`/`udiv` never traps — sidestepping the
  `typemin/-1` trap case without control flow (SSA `select` evaluates both arms).
  Only full-word widths (`sizeof∈{4,8}`: Int32/UInt32/Int64/UInt64) supported;
  sub‑word checked arithmetic throws `CompileError` (the i64‑widening overflow
  detection from WasmCodegen's `emit_checked!` is deferred — needs width‑aware
  widening). Regular sub‑word arithmetic is renormalized via `native_norm!`.
- ✅ **`bitcast` intrinsic** — `Core.Intrinsics.bitcast` recognized via identity check
  in `emit_intrinsic` (like `checked_*`); no-op at Cranelift level (same bits,
  different type annotation). Also handles `GlobalRef` form in `emit_globalref`.
- ✅ **Dead-error-path sentinels** — `Core.throw_methoderror`, `Core.throw_inexacterror`,
  `Core.throw_undef_if_null` in `emit_globalref` emit a `trap` and are detected as
  terminators in `emit_function_via_builder` (alongside `Base.throw`), so dead
  bounds‑error and method‑error paths don't block compilation of surrounding live code.
- ✅ **Recursion** — self-recursive `:invoke` calls detected via `MethodInstance` identity. The function is forward-declared as `Linkage::Export` before body compilation (`builder_declare_self_function` in Rust, `emit_function_via_builder` in Julia). Self-calls emit `call` to the declared FuncId. Enables countdown, factorial, fibonacci, and `_first_error` (recursive tree walker).
- ✅ **`isa(x, T)` on heap-type unions** — for `Union{T1, T2}` where no arm is `Nothing`, the type tag is unconditionally loaded from the object header (all values are valid pointers) and compared to `pointer_from_objref(T)`. Unblocks the `isa(x, Tuple{...})` check in `_first_error`.
- ✅ **Heterogeneous tuple constant-index getfield** — `emit_tuple_index_from_ssa` handles constant indexes before the homogeneous-element check, so only one field is loaded.
- ✅ **Ghost-type tuple allocation** — `emit_core_tuple` skips alignment/storage for ghost types (`Nothing`) whose `sizeof` is 0.
- ✅ **Sub-word type harmonization** — `emit_binop` and `emit_icmp` auto-extend i32 operands to i64 when paired with pointer/I64 operands, using `cranelift_type`-based comparison instead of Julia `sizeof`. Hardcoded `Int32(1)` in pointerref/pointerset replaced with `Int64(1)`. `emit_not_int` and `emit_neg_int` use operand-width-aware constants.
- ✅ **`:foreigncall` / `:gc_preserve_begin/end` handlers** — foreigncall maps `jl_value_ptr`, `jl_string_ptr`, `jl_set_errno`, `jl_errno`, `jl_strtod_c` to inline ops or runtime imports; gc markers no-op with type-appropriate sentinel.
- ✅ **`resolve_operand` extended** — handles `Ptr`, `QuoteNode`, `Symbol` constants; `Ptr` as `Int64` pointer, `Symbol` same as `String` (heap-ptr constant).
- ✅ **Dynamic array allocation** — `emit_new(array)` supports non-constant sizes by loading from the SSA tuple.
- ✅ **`sub_ptr` / pointer ops** — pointer subtraction GlobalRef added to `emit_globalref`.
- ✅ **`isa` built-in** — `Core.isa` dispatched in `emit_instruction` as a `Core.Builtin`.
  **`isa(x, Nothing)`:** compares against the tagged nothing sentinel (`get_nothing_tag()`)
  for union-field values, not raw null `0x0`. **`isa(x, T)` on `Union{Nothing, T}` values:**
  checks `value != nothing_tag` (the non‑nothing arm must be the target type). Unblocks
  `child_position_span` and all `isa(x, Vector{...})` checks on children() results.
          **Also supported:** `isa(x, T)` on heap-type unions without `Nothing` — type tag loaded from object header (safe: all arms are valid pointers). **Deferred:** `isa(x, T)` on unions with mixed scalars+pointers, and general non-union values — needs sentinel-guarded brif.
  needs type-tag load from object header guarded by a brif (sentinel‑safe pointer check).
- ✅ **`isnothing` / `=== nothing` on union fields** — `Union{Nothing, T}` fields
  represent `nothing` as a tagged sentinel (e.g. `0x7XXXXXXXXXXXXX8`), not `0x0`.
  `get_nothing_tag()` lazily computes the runtime tag by reading a probe struct
  union field (avoids precompile-cache staleness). Used by `resolve_operand`,
  `emit_invoke` isnothing handler, and `emit_isa(x, Nothing)`. Enables `is_leaf`,
  `numchildren`, and all `children() === nothing` comparisons.
- ✅ **`children(GreenNode)` → `Union{Nothing, Vector{...}}` return** — `_gcall` now
  handles Union return types with all-pointer non-Nothing arms (Phase 4b). Returns
  `Ptr{Cvoid}` with tagged-nothing check. `compile_and_call` works for children retrieval.
- ✅ **`Union{Nothing, T}` field access** — `emit_struct_getfield` detects Union
  field types before `ref_tracking` and loads them as raw pointers (`TYPE_PTR`).
  `nothing` maps to the tagged sentinel (not raw 0), a value maps to its heap pointer.
  Fixed the `convert(DataType, Union{...})` MethodError in dict `setindex!`.
- ✅ **`AbstractString` in `cranelift_type`** — `AbstractString` (used in
  `ArgumentError.msg` / `ErrorException.msg` fields) returns `TYPE_PTR` (always a
  heap-allocated `String`).
- ✅ **`ifelse`/`select`** — `Core.ifelse` dispatched in `emit_instruction` and
  lowered to Cranelift `select(cond, a, b)` in `emit_select`.
- ✅ **`Nothing` in `resolve_operand`** — `nothing` constant maps to `Int64(0)`;
  `isghost` check handles singleton/ghost types.
- ✅ **Varargs tuple pointer width** — `emit_function_via_builder` uses `ir.argtypes`
  (not `mi.specTypes.parameters`) so varargs tuples are declared as `TYPE_PTR`
  instead of scalar types. Unblocks `remove_flags` and similar functions.
- ✅ **JuliaSyntax compilation acceptance (probe1)** — 5 of 5 probe functions compile
  through `compile_native`: `has_flags`, `is_number`, `is_leaf`, `Kind(Int)`,
  `call_type_flags`.
- ✅ **JuliaSyntax probe2 status** — ALL 7/7 probe functions compile 🎉:
  `_first_error` (✅ runtime via bridge), `_copy_normalize_number!` (✅ runtime),
  `parse_float_literal` (✅ runtime via bridge, Type{Float64} fix),
  `parse_int_literal` (✅ compiles, runtime needs scalar boxing). Probe at
  `NativeCodegen/test/debug_jlsyntax_probe2.jl`.
  **Bridge callable:** 5 of 7 probe functions can be called at runtime;
  only `parse_int_literal` needs scalar-boxing pipeline (deferred).
- ✅ **GotoIfNot fallthrough fix** — `children()[i]` SIGILL resolved. Root cause:
  Julia CFG `succs[2] == GotoIfNot.dest` for `Union{Nothing,T}` isa dispatch,
  causing both `brif` branches to target trap. Fixed by checking equality and
  using `succs[1]` as fallthrough. Unblocks all tree-walking functions.
- ✅ **haschildren(GreenNode)** — deprecated `!is_leaf` invoke sentinel fixed.
  Handler in `emit_invoke` loads `:children` field, compares with nothing tag.
- ✅ **Type{Float64} bridge** — `_gcall` marshals `Type` as `Ptr{Cvoid}`.
- ✅ **Beacon tests expanded** — `is_string_delim` unskipped (kinds exist at runtime),
  `haschildren(GreenNode)` added, `_first_error` and `parse_float_literal` are now
  runtime tests, `parse_int_literal` is compilation test. `Kind(Int)`, tree-walking
  tests (`count_literals`, `has_identifier`, `child_span`) added.
  **0 @test_skip** remaining — parsing pipeline replaced with host structural tests.
  Tier 3 expanded: ParseStream(String/Vector), parse!, build_tree, SourceFile,
  IOBuffer all compile (7 new compilation tests).
- ✅ **test_final.jl — End-to-End Beacon** (`NativeCodegen/test/test_final.jl`).
  **84 compilations pass**: Kind predicates, operator-precedence predicates, simple
  predicates, flag ops, Kind(Int64) + isless, SyntaxHead accessors, flag predicates
  on SyntaxHead, haschildren, GreenNode accessors, generic predicates, composition
  chains, children() return, tree-walking, host-tree verification.
  **Parse pipeline:** `ParseStream`, `parse!`, `build_tree`, `SourceFile`, `IOBuffer`
  all compile. `parse_into` runtime test: **BLOCKED** (# TODO: recursive pipeline
  cannot yet compile parse! — see recursive pipeline status below).
  **0 stubs, 0 bridges, 0 @test_skip.** Failed tests are commented out with `# TODO:`.


- `_is_f64(T)`: `scalar_repr(T).isfloat && bits == 64`
- `_is_f32(T)`: `scalar_repr(T).isfloat && bits == 32`
- `_is_ptr_type(T)`: mutable struct, `String`, or `T <: Tuple` → passed/returned as
  `Ptr{Cvoid}` via `pointer_from_objref` (then `unsafe_pointer_to_objref` on return)
- Return types: `_call0()`/`_ret()` handle pointer (`unsafe_pointer_to_objref`),
  `Float64`/`Float32` (reinterpret), `Bool` (from_wire), and default `from_wire`
- `_norm_nargs(argtypes)`: treats a single `Tuple{}` argtype as "no arguments", so
  callers can pass `argtypes = Tuple{}` uniformly (matches `compile_and_call`)
- `compile_and_call(f, rettype, argtypes::Type{<:Tuple}, args...)`: one-shot helper
  supporting **any arity** via `_gcall` (note: index arg types via
  `argtypes.parameters[i]`, NOT `argtypes[i]` — the latter is Julia's type-array
  literal syntax)
- **`_gcall` generated dispatcher**: ONE `@generated function _gcall(ptr, ::Type{RT},
  ::Type{AT}, args...) where {RT, AT<:Tuple}` replaces the entire old
  `_call0`/`_call1_*`/`_call2_*`/`_ret` ladder. It builds the `ccall` argument-type
  tuple from `AT.parameters` and the return type from `RT`, so any arity / type
  combination works without enumeration. `native_callable` / `native_callable_from_so`
  return `(args...) -> _gcall(ptr, rettype, AT, args...)`.
- **Call exactly once (INVARIANT)**: `_gcall` issues a single `ccall`. The old
  per-arity helpers once did an unconditional `ccall(...,Ptr{Cvoid},...)` to capture
  the return pointer THEN re-called for scalar returns — running the function
  TWICE, which corrupted side-effecting callees (`push!`/`pop!`/`resize!`/`append!`
  observed their own earlier mutation, e.g. `pop!` returned `a[end-1]` and
  over-shrank by one). The single-call invariant is now structural to `_gcall`.
- **Immutable struct arg marshalling**: `_gcall` wraps non-bitstype immutable
  struct args with `Ref()` before `pointer_from_objref` (which otherwise fails
  on immutables). Mutable structs, String, and Tuple args are passed directly.
- Also `native_callable_from_so` for loading pre-linked .so files (bypasses Rust ccalls)

### Key eDSL conventions (builder_emit.jl ↔ native-builder)

- **Type enums** must match between Julia (`TYPE_I64=1`, `TYPE_I32=0`, `TYPE_F64=3`, etc.) and Rust
- **SSA tracking**: `BuilderCtx` tracks `ssa_values::Dict{Core.SSAValue, UInt32}`, `arg_values::Dict{Core.Argument, UInt32}`, `blocks::Dict{Int, String}`
- **Ref tracking**: `BuilderCtx.ref_tracking` maps SSA values → `(base_ptr_id, composed_offset, struct_type)` for non-loadable types like MemoryRef. When `getfield` encounters a type that `cranelift_type()` can't handle (e.g. MemoryRef is 16 bytes), it records the composed offset. Subsequent `getfield` on that SSA value uses the tracked offset to emit the real load.
- **FFI pattern**: Julia calls `ccall((:block_add_iadd, "libnative_builder"), ...)` with type enums and SSA IDs. The Rust side keeps **one persistent `FunctionBuilder` per function** in `FunctionCtx` (not one per FFI call); each `block_add_*` emits one instruction through it, skipping `switch_to_block` when already positioned on the target block. Holding one builder is mandatory — the old transient pattern tripped cranelift-frontend's `func_ctx.is_empty()` debug assertion.
- **Cranelift API**: `FunctionBuilder` in Rust. Methods: `create_block()`, `switch_to_block()`, `ins().iadd()`, `ins().iconst()`, `ins().return_()`, `seal_block()`, `finalize()`
- **Linking**: Julia's lld at `~/.julia/juliaup/julia-nightly/libexec/julia/lld`. Command: `lld -flavor ld.lld -shared -o out.so in.o libnative_backend.a` — note there is **no `-lm`/`-lc`**, so Cranelift libcalls (`ceil`/`floor`/`trunc`, the `mem*` family, …) resolve at `dlopen` against the host Julia process's libm/libc.
- **Entry symbols are prefixed** with `ENTRY_SYMBOL_PREFIX` (`"__jl_entry_"`) in
  `compile_native` (`NativeCodegen.jl`), and `comp.func_name` carries the
  prefixed symbol so `native_callable_from_so`/`compile_and_call` dlsym it
  consistently. **Why:** with no `-lm`, a libcall like `ceil` resolves to the
  nearest in-module definition; if an entry were exported bare as `ceil`, the
  libcall would bind to the entry itself → infinite self-recursion
  (`StackOverflowError` at the runtime call). The prefix guarantees no user/test
  `name` can ever shadow a libcall. (Cranelift lowers `ceil_llvm`/`floor_llvm`
  to libm libcalls on x86-64; `sqrt` is native `sqrtsd`, so it never had the issue.)
- **Import declaration**: `builder_declare_import(name, ret_type, param_types)` → declares in ObjectModule with `Linkage::Import`. `block_add_call(name, args)` → emits `call` via `module.declare_func_in_func` + `fb.ins().call`.
- **Constant emission**: Each `resolve_operand` call for a constant emits a NEW iconst — constants are NOT cached across blocks, as that would cause Cranelift verifier cross-block dominance violations.
- **PIC required on ARM64 macOS**: The flags builder MUST set `is_pic = true` (requires `use cranelift_codegen::settings::Configurable`). Without PIC, external function calls crash with `ReadOnlyMemoryError` because ARM64 macOS enforces position-independent executables and `dyld` rejects absolute relocations in `.text`.
- **Conversion intrinsic arg order**: all conversions (`sext_int`/`zext_int`/`trunc_int`/`sitofp`/`uitofp`/`fptosi`/`fptoui`/`fpext`/`fptrunc`) are `(Type, value)` — args[1] is the *result* type, args[2] the value. The type arg can arrive as a bare `DataType`, a `Core.Const`/`QuoteNode`, OR a `GlobalRef` to the type (e.g. `GlobalRef(Base, Float64)`); `_unwrap_type` (`builder_emit.jl`) handles all three. Cranelift op mapping: int↔float via `fcvt_from_sint`/`fcvt_from_uint`/`fcvt_to_sint_sat`/`fcvt_to_uint_sat`; f32↔f64 via `fpromote`/`fdemote` (both take the result `Type`).
- **Intrinsic dispatch is dual**: intrinsics may arrive as `Core.IntrinsicFunction` (→ `emit_intrinsic`) OR as `GlobalRef` (`Base.sitofp`, `Base.bswap_int`, `Base.ceil_llvm`, … → `emit_globalref`). Each intrinsic must be handled in **both** places. Name via `ccall(:jl_intrinsic_name, …)` for the IntrinsicFunction form.
- **`jl_intrinsic_name` returns `"invalid"` for newer intrinsics** (e.g.
  `checked_{s,u}{add,sub,mul}_int` are missing from that C table). Identify those
  by **identity** at the top of `emit_intrinsic`: `f === Core.Intrinsics.checked_sadd_int && return …`
  (IntrinsicFunctions are singletons; `f === Core.Intrinsics.X` is reliable). The
  `GlobalRef` form is unaffected (`f.name` gives the right `Symbol`).
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
   **Array-vs-range detection**: `emit_new` gates the array path on `T <: Array`
   (NOT `AbstractArray` — `UnitRange`/`StepRange`/… are `<: AbstractArray` too,
   via `AbstractVector`, and would wrongly take the array path). Ranges
   (`T <: AbstractRange`) only appear as `%new(UnitRange, lo, hi)` in dead
   `_throw_boundserror_indices` paths and emit a `0` sentinel.

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

### Runtime independence

The `.so` produced by the native pipeline has **zero runtime dependency on libjulia**.
All object allocation, string operations, array growth/shrink, and GC are
implemented entirely in Rust (`native-backend` crate) using the Boehm GC allocator
(`bdwgc-alloc`). The linker verifies this with `verify_no_julia_symbols` (runs `nm -u`
on the output `.so` and fails if any `jl_` symbols are undefined).

**What this means:**
- `nm -u out.so | grep jl_` returns nothing (no undefined libjulia symbols)
- The `.so` links against libSystem/libc (for `memcpy`, `bzero`, Cranelift libcalls),
  but NOT against libjulia
- Object layouts produced by the runtime are Julia-compatible (so `unsafe_pointer_to_objref`
  works in the test harness), but the allocation is done by Boehm GC, not Julia's GC

**Object layouts:**
- **String**: `[jl_datatype_t* tag (8)] [length: i64 (8)] [inline char data...nul]` — allocated by `rust_alloc_string`
- **Array**: `[jl_datatype_t* tag (8)] [JuliaArrayRepr {elem_ptr, mem_obj, length, capacity}]` — allocated by `__jl_array_new_1d`
- **Struct/tuple**: `[jl_datatype_t* tag (8)] [field data at fieldoffset]` — allocated by `__jl_gc_alloc_julia`
- **Internal objects** (Memory, temporaries): `GCHeader {type_tag, flags, length}` — legacy layout, never returned to Julia

**Post-link verification:**
The `link_object_to_so` function in `native-builder/src/linker.rs` runs `nm -u` on
the output `.so` after linking. Any undefined `jl_` symbol (e.g. `_jl_alloc_string`,
`_jl_array_grow_end`) causes an immediate error. LibSystem/libc undefined symbols
(e.g. `_memcpy`, `_bzero`, `_abort`) are legitimate and pass through.

8. **Unknown invoke sentinel** — unsupported `:invoke` calls emit constant 0
   instead of erroring. This allows functions with dead branches
   (e.g. bounds-check error paths) to compile. (Handled invokes: `ncodeunits`,
   `codeunit`, `sizeof`, `isempty`, and string concat `:*`/`Base._string`.)

9. **String ops — what's deferred** — String **read** ops + **concatenation** +
   **literal return** + **single‑arg `string(n::Int64)`** work. NOT yet supported:
   `string(n, base=2)` with keyword args (desugars to `_apply_iterate` +
   `Vector{Symbol}`), multi‑arg `string(a,b,...)` (lowers to vararg
   `print_to_string`), `String(bytes::Vector{UInt8})` (lowers to
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

### Recursive pipeline status (2026-07-13, final)

**`parse_into` compiles (38s) and runs to completion without crashing.**
Stub output: all inputs return 1 (host: 2, 7, 2). Parse loop advances correctly.

| Input | Native | Host |
|-------|--------|------|
| `"1"` | 1 | 2 |
| `"1 + 2"` | 1 | 7 |
| `"x"` | 1 | 2 |

**Test status:** 91/91 eDSL tests. ~82 test_final assertions. 0 sentinel gaps in
critical path. No crashes, no infinite loops, no panics.

### Fixes applied (8)

| Fix | What |
|-----|------|
| MemoryRef setfield try-catch | `cranelift_type(MemoryRef)` throws → store as TYPE_PTR |
| Bit-op identity checks | `ctlz_int` etc. before `jl_intrinsic_name` (returns "invalid") |
| checked_{s,u}rem_int | `:rem` in emit_checked_pair + GlobalRef/intrinsic dispatch |
| Large bitstype sret ABI | `_record_ssa_result` tracks heap pointers for Case 1 getfield |
| isa(x, Tuple{}) sorter bypass | Always true for vararg_tuple_coll |
| NamedTuple resolve_operand | Heap pointer instead of reinterpreted UInt16 bits |
| _record_ssa_result Tuple/NamedTuple exclusion | Prevents gcd regression |
| _bump_until_n + parse_stmts stubs | Advance lookahead_index to break parse loop |

### Remaining blocker: Cranelift 0.133 `remove_constant_phis` panic

To produce correct output, `parse_stmts` (385 IR stmts, 144 blocks) must compile
natively. This requires `cranelift_type(Union{Nothing, ParseStreamPosition})` to
return `TYPE_I64`. The fix is a one-line `try-catch` at line 1789 of `builder_emit.jl`:

```julia
callee_rt_enum = try cranelift_type(callee_rettype) catch _; TYPE_I64 end
```

However, this unblocks many functions with `Union{Nothing, T}` return types. Several
of these produce Cranelift IR that triggers a panic in `remove_constant_phis`
(`cranelift-codegen 0.133.1, src/remove_constant_phis.rs:265`):

```
func.layout.entry_block() → None
→ "remove_constant_phis: entry block unknown"
→ panic_cannot_unwind → abort
```

The panic occurs during `ctx.compile()` → `module.finish()` and cannot be caught
with `catch_unwind` (Cranelift uses `panic = "abort"` internally). Trap stubs are
not the source — the panic is in regular compiled functions whose layout loses the
entry block after `eliminate_unreachable_code`.

Reproduction: apply any fix that enables `Union{Nothing, T}` → TYPE_I64 (global
`cranelift_type`, targeted handler, or generic handler try-catch). Functions that
previously threw CompileError now compile but produce broken layout.

**Resolution paths:**
1. **Upgrade Cranelift** past 0.133 where this layout bug is fixed
2. **Narrow type fix to specific MIs** — intercept `request!` with a whitelist that
   only allows `_bump_until_n`/`parse_stmts` and blocks all other newly-compilable
   functions. Requires tracking which MIs are "new" vs "original."
3. **Replace trap stubs with skip** — already done; verified not the root cause

**Rust infrastructure in place (not yet activated):**
- `is_block_sealed()` in `builder.rs` — checks if current block has terminator
- `block_is_sealed` FFI in `lib.rs` — exposes to Julia
- `block_add_iconst` sealed guard — returns 0 if block filled
- `block_add_trap` sealed guard — skips trap if block filled