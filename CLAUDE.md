# Julia → Native Codegen

Native-ahead-of-time compiler for Julia: compiles Julia functions through
Cranelift's programmatic eDSL (`ObjectModule` + `FunctionBuilder`) and links
them with a pure-Rust runtime (`native-backend`) into a standalone `.so` —
callable from pure Rust (or any C-FFI consumer) with zero Julia dependency.

**CLIF text is abandoned.** Never add CLIF serialization or parsing.

## Environment

- Native codegen requires **Julia nightly** (`julia +nightly`): the overlay
  interpreter (`NCGInterp`) needs `Core.Compiler.InferenceCache`, which is absent
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
  files under `NativeCodegen/test/`. Permanent native tests belong in
  `test_edsl_approach.jl` or another `test_*.jl` file.
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
  → NCGInterp (overlay interpreter)
  → optimized Julia IRCode
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

### Shared frontend facilities

These target-agnostic facilities live in `NativeCodegen/src/`:

| Facility | Source | Use |
|---|---|---|
| `NCGInterp` | `NativeCodegen/src/interp.jl` | Overlay `AbstractInterpreter`; the `NCG_MT` table replaces C-call-backed Base primitives (utf8proc, memcmp, memset, objectid) with pure-Julia equivalents that the emitter can lower |
| `ScalarRepr`, `_SCALAR_REPRS` | `NativeCodegen/src/reprs.jl` | Julia type → value representation |
| `scalar_repr`, `isghost`, `ghost_instance` | `NativeCodegen/src/reprs.jl` | Representation/type queries |
| `from_wire`, `to_wire` | `NativeCodegen/src/reprs.jl` | Julia ↔ wire conversion |
| `CompileError` | `NativeCodegen/src/NativeCodegen.jl` | Unsupported-lowering error |
| `CC` | Julia compiler internals | `Core.Compiler` alias |

The `NCG_MT` overlay table is minimal — operations the emitter handles natively
(`ncodeunits`, `codeunit`, `sizeof`, `push!`, `resize!`, `unsafe_copyto!`,
scalar arithmetic) do NOT go through overlays. Only these C-call-backed Base
functions are overlaid: Unicode classification (`is_id_start_char`, `is_id_char`,
`category_code`, `isgraphemebreak!` — backed by `charmap.jl` and vendored
`UnicodeNext`), Dict lookup (`ht_keyindex` → linear scan), string equality
(`_str_egal`), `fill!` (loop), `findnext` (loop), `unsafe_wrap(Vector{UInt8},String)`
(loop), and the strtod/strtof float-parsing bridge.

## Source layout

| Path | Role |
|---|---|
| `NativeCodegen/src/NativeCodegen.jl` | Module entry, compilation/linking entry points, callable ABI dispatch |
| `NativeCodegen/src/builder_emit.jl` | IRCode → eDSL emitter, SSA/control-flow/invoke/MemoryRef lowering |
| `NativeCodegen/src/interp.jl` / `reprs.jl` / `charmap.jl` | Overlay interpreter + minimal stubs, value representation, Unicode char tables |
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

## Standalone `.so` — the no-baked-pointer invariant

The emitted `.so` MUST be independent of the Julia process that compiled it, so
`examples/native_demo` can `cargo run -- lib.so "1 + 2"` from pure Rust (no Julia
loaded). The hazard is **baked Julia-heap pointer immediates** in `.text`
(`mov x0,#imm; movk; ret`): these only resolve in the compiling process and
SIGSEGV elsewhere. `linker.rs::verify_no_julia_symbols` does NOT catch them (it
sees only *undefined-symbol* refs, and `nm -u` shows zero `jl_` even for a
fully-baked `.so`). The real guard is **emit-time**: every heap value is
resolved at runtime inside the `.so`, never baked. The emit-time guard is
`_trace_bake` in `builder_emit.jl` (set `NCG_STRICT_BAKE=1` to turn any remaining
bake into a `CompileError`); the end-to-end guard is the pure-Rust demo.

Mechanisms (runtime symbols in `native-backend/src/runtime/gc.rs`/`strings.rs`,
all linked statically into the `.so`):

- **Type tags / `nothing` sentinel** — `__jl_type_tag(id)`/`__jl_nothing_tag()`
  over a `TYPE_TABLE` of distinct addresses. The Julia dispatcher
  (`NativeCodegen.jl::_register_types!`) overwrites each id with the real
  `pointer_from_objref(T)` in-process, so `unsafe_pointer_to_objref` and
  `_gcall`'s nothing comparison stay correct; standalone hosts use the BSS
  defaults (fine — type tags are only equality-compared, never dereferenced as a
  real `jl_datatype_t`). Every type-pointer site routes through `_emit_type_tag`.
- **String / Symbol / bitstype / Vector{bits} / Dict / NamedTuple / struct
  literals** — their bytes live in the `.so` as Cranelift data symbols
  (`builder_declare_data`/`define_data`, referenced via `symbol_value`); runtime
  helpers rebuild the object in the arena: `__jl_string_from_raw`,
  `__jl_bytes_dup`, `__jl_array_alias_rodata`, `__jl_dict_from_rodata` (rebuilds
  the Julia-layout hash table from slots/keys/vals, with String elements rebuilt
  per-slot), `__jl_intern_symbol` (interns by name ⇒ `===` identity).

- **Const memoization** — these rodata-sourced builders are wrapped by
  `get_or_build_rodata(key=rodata_addr, …)` over a thread-local `RODATA_CACHE`, so
  each const is built ONCE per parse (not per use — the emitter can't CSE across
  blocks; Cranelift dominance). `__jl_string_cached` is the memoized twin of
  `__jl_string_from_raw` (string literals); the demo's arg keeps the non-memoized
  `__jl_string_from_raw` (heap buffer, must not be cached). **`__jl_gc_reset`
  clears `RODATA_CACHE` and `SYM_INTERN`** — the cached objects are arena-allocated
  and would dangle after reset (a latent UAF for multi-input-per-process callers).
- **Checked-arithmetic direct value** — `emit_checked_pair` returns the value id
  (recorded in `ssa_values`) when the stmt type is NOT a `Tuple` (inference
  simplified `a%b` to its bare value, used directly as a loop phi); it returns
  `nothing` (pair read via `ssa_pairs`/`getfield`) only for the `Tuple` case.
  Without this, loop-carried `a,b=b,a%b` (gcd) hits "SSA value %N not found".

The demo's `String` argument is built by the `.so`'s own `__jl_string_from_raw`;
the entry returns an `Int64` (GreenNode count) that Rust prints directly. Probe:
`NativeCodegen/test/debug_standalone_parse.jl` compiles `parse_into` to a fixed
`.so`; `debug_standalone_so.jl`/`debug_standalone_disasm.jl` compile smaller
functions for `.so` byte/IR inspection.


## Adding native features

1. Reuse an existing facility in `NativeCodegen/src/` if it already implements the
   target-independent part; do not duplicate it.
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
  **`jl_intrinsic_name` returns `"invalid"` for nearly EVERY intrinsic on current
  Julia nightly** (add_int, sub_int, and_int, trunc_int, eq_int, … — all of them),
  so the name-based dispatch in `emit_intrinsic` is only reachable via the
  prebuilt `INTRINSIC_NAMES::IdDict{Core.IntrinsicFunction,Symbol}` table
  (built at module load from `names(Core.Intrinsics)`); `fn_sym` is resolved
  from that table, falling back to `jl_intrinsic_name` only for the rare entry
  not present. Arithmetic works despite this because `a + b` lowers to
  `Base.add_int` (a GlobalRef → `emit_globalref`, whose `.name` is correct); raw
  `(Core.Intrinsics.X)(...)` calls (e.g. `and_int`, `trunc_int` in checked
  conversions) go through `emit_intrinsic` and need the table. Do not rely on
  per-intrinsic identity checks alone — add new raw intrinsics by ensuring they
  are in `INTRINSIC_NAMES` (they are, automatically) and have a `fn_sym == :X`
  handler.
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
- **Recursive pipeline status (2026-07-16, updated):** `parse!`/`parse_stmts`
  WORK END-TO-END at runtime for simple expressions AND assignments **with the
  GC disabled** (`__jl_gc_alloc*` uses a thread-local bump arena — leak mode,
  reset via `__jl_gc_reset()` between suites). Runtime memory is 6–20 KiB per
  parse.
  - **Working natively:** `parse!("1 + 2")`→5, `parse!("x = 1")`→5,
    `parse!("a = b")`→5, `parse!("x = foo(y)")`→7,
    `parse!("x = 1 + 2")`→9, `parse!("1 + foo(y)")`→8,
    `parse!("a + b + c + d")`→13, `parse!("a + b + c + d + e")`→17.
    The `parse_into` full pipeline also works: `parse_into("1 + 2")`→5 ✅.
    WEB_CORPUS (kind/haschildren on GreenNode): 6/6 ✅.  Flag-op tests pass.
    Simple expressions, assignments, 1–3 arg calls, and binary ops all work.
  - **FIXED (2026-07-17) — function-typed arg widening dropped resword bodies
    (the module/function/struct WEB_CORPUS bug).** The overlay interpreter widens
    function values (e.g. parse_block's `down=parse_public`) to abstract
    `Function` in the `:invoke` MethodInstance. parse_block (compiled generic,
    `down::Function`) then calls `parse_block_inner` via a `:call` GlobalRef;
    `emit_globalref` had no handler for a callable GlobalRef, threw "Unsupported
    GlobalRef: ...parse_block_inner", and the call was sentinel'd + DCE'd — so
    parse_block became emit-only (it emitted `block` without parsing the body).
    For `module A\nend` this left the body-separator trivia unconsumed and
    `bump_closing_token` errored on the NewlineWs (+1 node). Two-part fix in
    `builder_emit.jl`: (1) `_respecialize_on_funargs` — at each `:invoke`, if a
    `Function`-typed param is passed a compile-time-constant function, rebuild
    the signature with `typeof(that_function)` and `Core.Compiler.specialize_method`
    the SAME method on it, recovering the concrete type the overlay interp lost;
    (2) `_emit_recursive_globalcall` — a callable GlobalRef in a `:call`
    (`parse_block_inner`) resolves like a `:invoke` (resolve MI, declare, emit
    cross-function call) instead of erroring. After this, `module A\nend`→9,
    `function f(a::Int,b)\n return a*b-2.5e3\nend`→33, `struct Point{T<:Real}…end`→25
    all match host (was +1 / −2 / −1). eDSL suite unchanged (89 ✅ / 3 pre-existing ❌).
  - **FIXED (2026-07-17) — 3+ postfix statements separated by newlines hit a
    runtime boundscheck (the try/catch/finally WEB_CORPUS case).** The last
    WEB_CORPUS snippet SIGILLed in `__throw_boundserror_indices`. Root cause: the
    `:size` store clamp in `emit_struct_setfield` (for Array `:size`) capped the
    stored value at **≥1** (added to keep the lookahead buffer's EOF sentinel
    during compaction). But `position_pool` legitimately drains to size 0 via
    `pop!`; the clamp made `isempty(position_pool)` never see 0, so
    `acquire_positions` popped a stale slot instead of returning a fresh
    `Vector{ParseStreamPosition}()` → OOB on the 3rd postfix statement (when the
    pool had been drained). Fix: clamp `:size` at **≥0** (not ≥1). A size of 0 is
    valid for non-lookahead Vectors; the lookahead buffer never legitimately
    empties, so its size stays ≥1 in practice and compaction still works
    (5-operand chains still parse, 19==19). After this, the try/catch/finally
    snippet → 32, `foo()\nbar()\nbaz()` → 15, `x[1]\ny[2]\nz[3]` → 18, all match
    host. **All 6 WEB_CORPUS now pass.**
  - **FIXED — `parse_RtoL` `lookahead_index` hoisting (Cranelift fence).** The
    egraph hoisted `getfield(stream, :lookahead_index)` across self-recursive
    `:invoke` calls, reading a stale value of 1 while `next_byte` was current.
    Fix: `fence` after self-recursive calls (`builder.rs` `emit_fence` +
    `lib.rs` `block_add_fence`; inserted in `emit_invoke`). Unblocks 4+ chained
    operands and assignment-with-call expressions.
  - **FIXED — `__jl_gc_*` → thread-local bump arena.** All `__jl_gc_*` +
    `__jl_array_new_1d` + `__jl_array_grow_end` + `rust_alloc_string` use
    `bump_alloc(total, 16)` in a `thread_local!` arena. `__jl_gc_reset()` frees
    all blocks; `unreachable!("oom")` on NULL. The rest of Rust uses the system
    allocator. `native_callable_from_so` loads `.so` with `RTLD_GLOBAL` so
    `ccall(:__jl_gc_reset, Cvoid, ())` works between test suites. eDSL 90 ✅
    (3 pre-existing failures: gcd/gcd2 SSA tracking, popsum array length).
  - **FIXED — `__jl_dbg_i64` linker error.** Removed the unconditional import
    declaration from `_declare_imports`.
  - **FIXED — `_register_row` / `__jl_array_grow_end` heap underflow (Bug B).**
    The old code allocated only data bytes and wrote length at `data - 8` → 8-byte
    underflow on every `push!`. Fix: full `[type_ptr][length][data…]` layout.
    Removes the SIGILL and 3 phantom trap stubs (parse_chain/generator/
    decl_with_initial_ex).
  - **DISPROVEN — compaction/"stale ref_tracking" theory.** Probe 2 (replicate
    the inlined compaction on `Vector{SyntaxToken}`) → host=native=3. MemoryRef
    lowering + :ref advance are correct.
  - **CONFIRMED — EOF handling works.** `_buffer_lookahead_tokens` Cranelift IR
    correctly loops, pushes tokens, exits on kind==161 (K"EndMarker"). Native
    `peek(s,6)` returns 161 matching host.
  - **CONFIRMED working natively:** `peek(stream,1)` (native=48=host);
    `push!`+read `Vector{SyntaxToken}` (host=native); `codeunit`/`length`/
    `ncodeunits` on `String`.
  - **ABI hazard (NOT the parse! bug):** host-constructed `ParseStream`/
    `Vector{SyntaxToken}` crashes native (host stores SyntaxToken inline, native
    assumes heap pointers). The real `parse!` constructs its stream inside native.
  - **(Mostly FIXED 2026-07-17; see the function-typed-arg fix above.)**
    function/struct/module definitions now parse with correct counts. The
    remaining failure is the try/catch/finally snippet, which needs 3+ call
    statements separated by newlines — see the "3+ call statements" REMAINING
    bullet above. (The earlier `#untokenize#7` / `_nonunique_kind_names` theory
    was a misdiagnosis: bump_closing_token's error path was a *symptom* of the
    body never being parsed, not the cause. The cause was parse_block_inner
    being dropped — fixed.)
- **Sub-word array element load width:** `cranelift_type(Bool)` returns `TYPE_I32`
  (Bool occupies an i32 register per the shared `scalar_repr` convention), but in
  a `Vector{Bool}` each element is 1 byte in memory. `emit_memoryrefget` must load
  the **memory width** = `sizeof(elem)` bytes (Bool→`TYPE_I8`, UInt16→`TYPE_I16`;
  heap-pointer elements stay `TYPE_PTR`) then `uextend` to the register repr —
  otherwise a `load.i32` at a 1-byte stride reads 4 adjacent elements (this was
  the lexer bug that made `lex_identifier` stop after one identifier). The same
  memory-width rule should be applied to `emit_pointerset` (sub-word stores) and
  to `emit_struct_getfield` bitstype-field loads for completeness.
- **`Base.getglobal(module, :name)`** (how const globals are accessed in lowered
  IR) must be handled in `emit_globalref`: args[1] is a `GlobalRef` to the module
  (resolve via `getglobal(ref.mod, ref.name)`), args[2] is the `QuoteNode` name;
  resolve `getglobal(mod, name)` and `emit_constant` it. Without this, const
  `Vector{Bool}` tables like `ascii_is_identifier_char` read as garbage.
- **Entry block can't be a Cranelift branch target:** Julia IR block 1 is
  frequently a `while`-loop condition with a back-edge to itself
  (`parse_chain`, `parse_generator`, …). `init_entry` creates a synthetic entry
  holding the function params and immediately `jump block0`, so `block0` is a
  normal branch-targetable block. (Julia block 1 has no phi nodes in these
  cases, so the jump passes no args; param SSA values stay valid since entry
  dominates.)
- **`cranelift_type` for Unions:** a `Union{Nothing,T}` (and 3+-arm
  `Union{Nothing,T1,T2}` with a `TYPE_PTR` arm) must not throw — classify by the
  non-Nothing arms (drop the void arm); if they agree, return that type; if any
  arm is `TYPE_PTR`, return `TYPE_PTR` (scalars box at phi edges). Without this,
  functions whose inference-widened return is such a Union (e.g.
  `parse_unary::Union{Nothing,ParseStreamPosition,RawGreenNode}`) fail recursive
  resolution, the call is sentinel'd + DCE'd, and the function is never invoked.
- **Constant >8-byte bitstypes** (e.g. a folded `RawGreenNode(...)` literal) must
  be emitted as **rooted** heap pointers (`pointer_from_objref(Ref(val))`, pushed
  into the module-global `_ROOTED_CONST_REFS`); without rooting the GC reclaims
  the `Ref` after `compile_native` returns and the pointer dangles.
- **`cranelift_type(Union{})` must return a type, not throw.** `Union{}` (the
  bottom type) appears in kwcall sorter return types (from `kwerr` error paths).
  Without handling it, the sorter's recursive callee resolution fails
  (`got_ir=false`) → `bump_dotted` is sentinel'd → the `=` token is never consumed
  → `parse_assignment_with_initial_ex` recurses forever. Fix: `T === Union{} && return TYPE_I64`.
- **Case 3 getfield `offset == 0` shortcut must check field width.** A bitstype
  like `ParseStreamPosition` (8 bytes, `cranelift_type` → TYPE_I64) with
  `byte_index::UInt32` at offset 0 must NOT use `return obj_id` — that returns
  the full 8-byte packed value instead of just the low 4 bytes. Fix: only shortcut
  when `sizeof(field_T) >= sizeof(T)` (field fills the entire struct). Otherwise,
  fall through to shift+mask extraction.
- `remove_constant_phis` is **not** a Cranelift defect and is **not** opt-gated:
  it runs unconditionally in `Context::optimize` (only the egraph pass depends on
  `opt_level != none`). It requires `func.layout.entry_block()` to be `Some` —
  i.e. at least one block must be in the layout, and a block only enters the
  layout when an instruction is emitted into it. Two guards in
  `native-builder/src/builder.rs` hold that invariant so a half-emitted or
  unverifiable callee never aborts the whole module link: `finalize_ctx` emits a
  trap into the entry block when the layout is empty (a body whose emission threw
  before any instruction landed), and `finalize` defines a trap stub for any
  function that fails verification (so a pre-declared `Linkage::Export` callee
  never leaves `ObjectModule::finish()` aborting — it *panics*, does not return
  `Err` — on an undefined symbol). `opt_level` is `speed` (egraph on); a former
  `opt_level = "none"` did not in fact skip this pass.
- When rethrowing from emission, preserve a real terminator in the current block.
  Otherwise later block switching produces misleading invalid-block/no-terminator
  verifier errors; use `NCG_TRACE_RETHROW` to identify the original exception.
