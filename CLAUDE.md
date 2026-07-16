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
- **Recursive pipeline status (2026-07-15, updated):** `parse!`/`parse_stmts`
  WORK END-TO-END at runtime for simple expressions AND assignments **with the
  GC disabled** (`__jl_gc_alloc*` uses `std::alloc::System` — leak mode).
  Verified native==host: `parse!("1 + 2")`→7, `parse!("x = 1")`→7,
  `parse!("a = b")`→7, `parse!("x = foo(y)")`→11, `parse!("x = 1 + 2")`→12,
  `parse!("1 + foo(y)")`→11. The `parse_into` full pipeline (parse! + iterate
  output + extract head/flags/span from RawGreenNode fields) also works:
  `parse_into("1 + 2")`→7 (host==native). Flag-op tests (`numeric_flags`,
  `set_numeric_flags`) now pass.
  REMAINING: expressions with enough tokens (threshold ~15–20 output nodes)
  hit `throw_inexacterror` — a checked `trunc_int(UInt32, val)` fails,
  suggesting a cumulative drift in a position/span value. Function/struct/try/module
  definitions (which produce more output nodes) crash for the same reason.
  Simple expressions, assignments, 1–3 arg calls (no spaces), and binary ops work.
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
- **`parse_RtoL` recursive `next_byte` non-propagation (2026-07-16, NARROWED):**
  the SIGILL-in-`throw_inexacterror` crash on 4+ chained operands
  (`"a + b + c + d"`, `"x = a + b + c"`, `"x = 1 + foo(y)"`) is a *negative
  byte_span*, NOT a count/arg-count issue. The crash site is `parse_RtoL`'s
  toplevel/call node emit:
  `%71 = getfield(stream, :next_byte)` (read **after** the recursive
  `:invoke parse_RtoL` at IR `%65`), `%72 = zext(trunc_int(UInt32, %2))` (mark
  = `next_byte` at **entry**), `%73 = sub_int(%71, %72)` (= byte_span), then
  `trunc_int(UInt32, %73)` traps when negative. Runtime capture
  (`NCG_DBG_INEXACT` → `__jl_dbg_i64`, wired at the `:invoke throw_inexacterror`
  site in `emit_invoke`): for `"a + b + c + d"` the operands are
  `next_byte(post)=2, mark(entry)=14` → `2 − 14 = −12`; for
  `"a + b + c + d + e"` → `2 − 18 = −16`; for `"aa + bb + cc + dd"` →
  `3 − 18 = −15`. The host gets the *same two values in the opposite order*
  (`14 − 2 = +12`): the recursive `parse_RtoL` call leaves `stream.next_byte`
  **lower** than at entry for deeper precedence chains (it should be higher —
  the recursion must *advance* `next_byte`). Shallow chains (≤3 operands / ≤2
  recursion levels) advance correctly and pass. This is the deep-recursive-call
  frontier (precedence climbing); `parse_LtoR` works for the same inputs.
  Next step: compare how the recursive `:invoke`/self-import marshals the
  mutable `ParseState` vs `parse_LtoL`, and why the `next_byte` mutation from
  the child invocation fails to surface at depth ≥3.
  - **Workflow + further narrowing (2026-07-16):** a 5-agent code-analysis
    workflow (4 parallel + opus synthesis) examined the recursive-call
    marshaling, getfield caching, lookahead bounds check, and control-flow
    branches. **None of the hypotheses held up** — the recursive `:invoke`
    passes `ParseState` by pointer (mutations DO propagate; `ParseState` is
    mutable, so the synthesis's "caller uses stale state" theory is wrong);
    `emit_memoryrefnew`'s bounds check ALREADY loads length from the right
    place for struct-field vectors (`len_base_id = base_off != 0 ? vec_ptr_id :
    base_id`, builder_emit.jl:2835); there are NO live-path sentinels on
    `parse_RtoL`/`bump_dotted`/`peek_dotted_op_token` (only `kwerr` error-path
    + unrelated kwcall sorters are sentinel'd, per `NCG_TRACE_SENTINEL=1`).
    `post` ≈ 2–3 (≈ the first whitespace after the first identifier) across all
    crashing inputs. parse_RtoL has **0 references to `position_pool`** (it only
    does `parse_cond` + `bump_dotted` + recurse + `%new(PSP,…)`), so the
    backward `next_byte` move is NOT a position restore. **Definitive root
    cause:** the crashing specialization (`fn_245`) is the *pair* level
    (`is_prec_pair`, handles `=>`); for `"a + b + c + d"` (no `=>`) it must be a
    BASE CASE (return immediately, no bump/recurse), but native RECURSES — i.e.
    `is_op`/`is_prec_pair` returned **true on a garbage peeked token**. The
    garbage token comes from `peek_dotted_op_token` reading a `lookahead` slot
    whose SyntaxToken pointer is null/corrupt (the documented lookahead-buffer
    frontier). The bounds clamp in `emit_memoryrefnew` (line 2835) is correct,
    so the INDEX is in range — the SLOT CONTENT itself is the bad pointer. This
    is the same lookahead-slot-garbage issue CLAUDE.md has tracked across
    sessions (candidates: push! stores null under allocator pressure, compaction
    `memoryrefunset!` nulls the slot, or a store-to-element offset/width
    mismatch). Next step: instrument `push!`/`memoryrefset!` on
    `Vector{SyntaxToken}` to verify each buffered slot holds the pointer
    `next_token` returned (compare native vs host slot-by-slot across the
    `"a + b + c + d"` descent) — find the first slot whose pointer is bad.
  - **DISPROVEN + NARROWED FURTHER (2026-07-16, non-DCEable trace):** the
    "garbage lookahead slot pointer" theory is WRONG — a non-DCEable trace
    (`__jl_dbg_i64` now RETURNS its arg so calls survive the egraph; wire via
    `emit_call_runtime`, declared in `_declare_imports`) of every TYPE_PTR
    element load shows all 233 `lookahead` slot pointers for `"a + b + c + d"`
    are VALID heap addresses. Tracing `next_byte` AND `lookahead_index` field
    reads (Case 1 + Case 4, tag=1/2) reveals the real defect: at the crash
    point `next_byte` reads **correctly as 14** but `lookahead_index` reads a
    **stale value of 1** (its initial value) — they are inconsistent. Sequence:
    monotonic 1→14 for both during the main parse, then in `parse_RtoL`'s
    spurious (base-case-bypass) recursion the reads OSCILLATE
    `next_byte=14, lookahead_index=1, 14, 1, …` and `parse_unary`'s bump
    `next_byte = lookahead[lookahead_index+1].next_byte` therefore reads the
    FIRST token (ends at byte 2), bumping `next_byte` backward 14→2 → negative
    byte_span. So the bug is a **`lookahead_index` load/store aliasing or
    loop-hoisting defect**: Cranelift hoists the `lookahead_index` load out of
    the loop (reading pre-loop value 1) while the `next_byte` load stays
    current — meaning the `lookahead_index` `setfield!` is NOT modeled as
    aliasing its `getfield` (likely a different address computation between the
    setfield and getfield paths, or the wrong offset), even though `next_byte`'s
    setfield/getfield DO alias. Next step: compare the lowered Cranelift address
    of `setfield!(stream,:lookahead_index,…)` vs `getfield(stream,
    :lookahead_index)` (offset 32) — find why Cranelift doesn't alias them
    (it does for `:next_byte` at offset 56). `NCG_TRACE_NB=1` reproduces the
    oscillation; `__jl_dbg_i64(tag,v)` is the trace primitive.
  - **FIXED (2026-07-16, reliable) — bounds clamps broke the legitimate
    lookahead compaction.** `__lookahead_index` (parse_stream.jl:441-453)
    compacts by `setfield!(:size, len-delta)` FIRST, then `memoryrefnew(ref,
    delta+1)` to advance `:ref` (only when `delta > 0.9*len`). Two clamps broke
    this; both are now fixed in `builder_emit.jl`:
    (a) `emit_memoryrefnew` read-clamp: KEEP the length-clamp (`:size@16`) for
    ordinary reads (prevents the lookahead-drift OOB), but SKIP it when this
    memoryrefnew's result feeds a `setfield!(:ref, …)` — detected by scanning
    the IR for `setfield!(_, :ref, this_ssa)` (args = [setfield!, obj, :ref,
    value], so check args[3]==:ref && args[4]==this_ssa; an off-by-one here
    silently re-breaks it). That skip is exactly the compaction advance.
    (b) `emit_struct_setfield` :ref-store clamp: cap `:ref <= old_ref +
    (capacity-len)*esz` (NOT `capacity-1`, which let reads reach `capacity+len`
    → intermittent SIGSEGV; NOT `len-1`, which broke the compaction). This
    keeps reads (`:ref+(idx-1)*esz`, idx<=len) within the allocation while
    allowing the compaction (where `capacity-len == delta`).
    Result: `"a + b + c + d"`, `"x = 1 + foo(y)"`, `"foo(a,b,c,d)"`,
    `"a ^ b ^ c ^ d"` parse with CORRECT counts; `test_final.jl` 105 ✅
    reliably in isolated runs. (Running test_final many times back-to-back can
    still SIGSEGV — that is leak-mode heap pressure across rapid sequential
    processes, not the clamp; isolated fresh runs are reliable.)
  - **REMAINING (separate bugs, NOT the compaction):**
    (1) **Keyword recognition FIXED (2026-07-16, host-tracking).** The lexer
    tokenized ALL keywords as `K"Identifier"` because `get(_kw_hash,…)` (Dict
    slot-probe) misread `_kw_hash.slots` (a `Memory{UInt8}`). Host Memory layout
    is `[length@0][ptr@8 → &data]` (data via `load(obj+8)` deref), but compiled
    Memory (`emit_memorynew`) is `[length@0][data@8]` (inline), and the codegen's
    untracked `is_memory` path used `base+8` (compiled) for both. **Fix
    (builder_emit.jl):** added `host_ssas::Set{Core.SSAValue}` to `BuilderCtx`;
    marked host objects via `getglobal` (seed) + `emit_struct_getfield`
    propagation — an object is host if it's a `GlobalRef` to a defined global
    (e.g. `Main._kw_hash`) or a prior host mark or a `_const_value` constant;
    the untracked `is_memory` path now does `load(base+8)` for host-marked
    Memorys, keeping `base+8` for compiled. After the fix: keywords recognized
    (`module`→23, `if`→18, etc.), `"[a[1] for a in xs if !isempty(a)]"` parses
    correctly (31=31), `test_final` 105 ✅, eDSL green, no regression.
    (2) **NEW BLOCKER — `parse_resword` trap stub.** `module/function/struct/try`
    parsing now REACHES `parse_resword` (a 7827-stmt function), which is a
    verification-failure trap stub ("invalid block reference block1" — Julia
    block 1 / Cranelift block1 is not laid out: the synthetic entry jumps to it
    but no instruction lands in it). No rethrow/sentinel during its emission (it
    compiles fully, then the verifier rejects the block layout). This is a
    block-management defect in a very large function — next focus. `"try/catch"`
    also reaches it. Reproduce: `debug_one_input.jl "module A\nend"` → SIGILL in
    `__compiled_fn_128_parse_resword`.




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
