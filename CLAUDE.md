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
- **Recursive pipeline status (2026-07-15, updated):** `parse!`/`parse_stmts`
  now WORK END-TO-END at runtime for simple expressions **with the GC disabled**
  (`__jl_gc_alloc*` uses `std::alloc::System` — leak mode; see gc.rs). Verified:
  `parse!("1 + 2")` → 7 events (native==host), `parse!("1")`, `parse!("x")`,
  `parse!("1 + 2 * 3")`, `parse!("f(x)")`, `parse!("a + b * c")` all match host.
  This was unblocked by FOUR fixes this session: (a) disabling Boehm GC (its
  conservative scan was dropping `SyntaxToken` roots → dangling `lookahead[i]`
  deref — the day-long SIGSEGV); (b) the **sub-word struct/tuple field load
  width** fix (`_load_field_mem` in `emit_struct_getfield` Case 1/3b/4 +
  `emit_tuple_index_from_ssa`): a `Bool` field at tuple offset 1 was loaded as
  `load.i32` (4 bytes), reading into the adjacent `SyntaxToken` pointer →
  `is_compound_assignment` appeared `true` → `parse_assignment_with_initial_ex`
  infinite-recursed (stack overflow); now loads `sizeof(field)` bytes + `uextend`
  (floats keep their float type); (c) the **sub-word store width** fix
  (`_store_field_mem` in `emit_struct_setfield` + `emit_pointerset`): the
  store-side mirror — `store.i32` for a 1-byte Bool clobbered adjacent fields;
  (d) `emit_memoryrefget` memory-width (already applied, fix #11).
  REMAINING GAP: **assignment statements** (`x = 1`) still SIGILL — but it is
  `_parser_stuck_error` (peek_count > 100k), NOT an OOB: the assignment path's
  `bump("=")` doesn't consume the `=` token, so `parse_assignment_with_initial_ex`
  recurses forever re-peeking the same `=`. Simple expressions (no `=`) don't
  trigger it. Next: investigate why `bump`/`bump_dotted` is a no-op in the
  assignment context (works in the drain loop and for simple expressions). The
  GC-disabled leak mode is a diagnostic, not a long-term fix — proper Boehm
  rooting is the eventual replacement. Note: eDSL `popsum` (pop!×4) regressed
  under GC-off — it's the host/native Vector.size ABI hazard (native writes
  size as a heap Tuple pointer, host reads it inline), not a codegen bug.
  - **FIXED this session — `__jl_array_grow_end` heap underflow (gc.rs):** it
    allocated only the data bytes then wrote the length at `new_data - 8`, an
    8-byte underflow on every `push!`. This corrupted the Boehm heap, which in
    turn corrupted the Cranelift module state and produced *spurious* verifier
    failures (`parse_chain`/`parse_generator`/`parse_decl_with_initial_ex` →
    "invalid reference to entry block block0" → trap stub → SIGILL). The fix
    allocates the full `[type_ptr(8)][length(8)][data…]` Memory layout (mirroring
    `__jl_gc_alloc_array_julia`) so `mem_obj = new_data - 8` is a valid
    in-allocation field; this removes the SIGILL and those 3 phantom trap stubs.
    (Only the 3 known non-live-path stubs remain: `typejoin`, `parse_resword`,
    `first_child_position`.)
  - **DISPROVEN — the compaction/"stale ref_tracking" theory:** the prior note's
    leading hypothesis (stale tracked element address after `_deletebeg!`/
    `_growend_internal!`) is NOT the live trigger. Replicating `__lookahead_index`'s
    *inlined* compaction on a `Vector{SyntaxToken}` (null front δ, `setfield!(:ref,
    memoryrefnew(ref,δ+1))`, `setfield!(:size,len-δ)`, read `[1]`) gives
    **host=native=3** (correct). Direct Cranelift-IR reading confirms
    `lookahead[i] = element(δ+i)` as intended. So MemoryRef lowering + the
    `:ref` advance are correct.
  - **Confirmed working natively:** `peek(stream,1)` on a native-constructed
    stream (native=48=host); `push!`+read of `Vector{SyntaxToken}` (host=native);
    `codeunit`/`length`/`ncodeunits` on `String`.
  - **ABI hazard (NOT the parse! bug):** passing a *host*-constructed
    `ParseStream`/`Vector{SyntaxToken}` into native crashes — the host stores
    `SyntaxToken` (isbitstype, sizeof 12) **inline**, but native assumes
    heap-allocated **pointers** (`cranelift_type(SyntaxToken)=TYPE_PTR`,
    sizeof>8 → heap via emit_new). The real `parse!` constructs its stream
    *inside* native (native layout), so this only bites the callable bridge
    (`native_callable_from_so` with a `ParseStream` arg). Differential probes
    must construct streams inside the compiled fn.
  - **FIXED this session — `__jsonarray_lookahead_index` OOB read (builder.rs /
    builder_emit.jl).** The native codegen **never emitted bounds checks** for
    `memoryrefnew` (the `boundscheck` flag was documented but ignored — no code
    consumed `args[3]` in any `emit_memoryref*`). In contrast, **Wasm always
    OOB-traps on `array.get`** (modeled after `WasmCodegen/src/compiler.jl`
    line 1307). The parse's `__lookahead_index` advanced its index past the
    buffered tokens and, with `boundscheck=false`, read garbage → SIGSEGV.
    Fix: added a `trapnz` builder operation (`native-builder/src/builder.rs`
    `emit_trapnz` + `lib.rs` `block_add_trap_if`) and an unconditional bounds
    check in `emit_memoryrefnew` (tracked-base path): load `Vector+16` (the
    `:size` length), `icmp idx > len`, `trapnz` if true — matching Wasm's
    safety semantics. **After this fix the crash changes from SIGSEGV
    (garbage deref) → SIGILL (`ud2` trap, the Cranelift trap instruction)**;
    the parse still fails (the index IS going OOB), but fails safely.
    Regression-safe (eDSL 91 ✅).
  - **Bug B (`__jl_array_grow_end` heap underflow) also FIXED this session**
    (see above). Together Bug B + the bounds check account for all the
    fixes deliverable so far.
  - **Current remaining unknown:** WHY `lookahead_index` goes OOB in the
    composed descent (the bounds check fires cleanly in `__lookahead_index`,
    reached through `parse_assignment_with_initial_ex` deep recursion).
    The recursion guard (`%2 = getfield(peek_dotted_op_token(...), 1)` =
    `is_dotted` Bool) is correct in isolation (Probe `pdot_bool`: host=native=0),
    so the guard works; the index drift happens further downstream (multiple
    self-calls / parse cycle). Next step: differential-test the parser
    step-by-step on native-constructed streams (capture `lookahead_index`,
    `length(lookahead)`, and the peeked token kind at each step) to find
    the first state divergence where the index outpaces the buffer.
  - **CONFIRMED this session — EOF is NOT the cause.** The buffering loop in
    `_buffer_lookahead_tokens` (read from Cranelift IR at
    `/tmp/cranelift_dumps/__compiled_fn_45__buffer_lookahead_tokens.cranelift`,
    257 lines) correctly calls `next_token(lexer, 1)` in a loop, pushes each
    token via `push!` (grow+store), and exits when `kind == 161` (K"EndMarker").
    Native `peek(s,6)` (= the EOF sentinel at source end) returns **161**,
    matching host — so `next_token` correctly produces the EOF marker even
    after multiple real tokens. The OOB is therefore NOT from the lexer
    failing to return EOF or the buffering failing to push it. See
    `NativeCodegen/PARSEBANG_UNBLOCKERS.md` for the full history.
  - **CRITICAL NARROWING (clamp experiment):** The bounds-check `trapnz` was
    changed to a `select`-based **clamp** (`idx = min(idx, length)`) to prevent
    the OOB trap and let the parser run past the OOB. Result: the crash changed
    from **SIGILL (trap) → SIGSEGV (bad deref)**. This means the OOB index WAS
    hitting an unmapped address before; now the clamped index reads a valid
    buffer slot, but the **content of that slot is a garbage/null SyntaxToken
    pointer**, and dereferencing it causes the SIGSEGV. The garbage element is
    at the slot that SHOULD hold the EOF sentinel (kind 161). The root cause is
    therefore: why is the `SyntaxToken` pointer in the lookahead buffer slot
    garbage (null or corrupt)? Candidates: (a) the `push!` in the buffering
    loop stores a null pointer (Bohem GC `__jl_gc_alloc` returns null under
    memory pressure, or the store is miscompiled); (b) the compaction's
    `memoryrefunset!` nulls the slot erroneously (off-by-one, or the compaction
    and the buffering disagree on the slot index after `:ref` advance); (c) the
    `_buffer_lookahead_tokens` Cranelift IR stores at a wrong offset (the
    store-to-element instruction is at the wrong byte offset).
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
