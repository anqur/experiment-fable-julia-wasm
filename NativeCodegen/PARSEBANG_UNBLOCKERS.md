# NativeCodegen — `parse!` runtime unblockers

Goal: make `JS.parse!(JS.ParseStream("1 + 2"))` run end-to-end through
NativeCodegen. Probe: `NativeCodegen/test/debug_parse_bang.jl` (host = 7 events
for `"1 + 2"`).

**Status (2026-07-15):** `parse!`/`parse_stmts` COMPILE ~160 callees through the
recursive pipeline. At runtime the **lexer is correct** (`next_token`, `peek`,
`peek_token`, and the peek/bump drain loop all match the host for whitespace
inputs like `"a a"`, `"1 + 2"`, `"a a a"`), and every isolated parser function
(`parse_atom`, `parse_unary`, `parse_factor`, `parse_call`, `parse_power`,
`peek_behind`) runs correctly native. The full **composed** `parse!("1")` /
`parse_stmts("1")` still SIGSEGVs at runtime in `__lookahead_index` — a single
bad deref of `lookahead[i]` (a `SyntaxToken` pointer). All fixes are
regression-safe (eDSL suite 91 ✅, `test_final.jl` Tier 1-2 ✅).

## The architecture violation that was masking everything

`builder_emit.jl` had **stubs** for `parse_stmts` and `_bump_until_n` (added in
commit `b766925`) that bypassed the recursive pipeline — they bumped an index and
returned a zero sentinel instead of parsing. This violated the CLAUDE.md rule
"No import bridge for `parse!` or `ParseStream`." **Removed them** (route through
the `mc !== nothing` recursive path). After removal the real bugs became visible.

## Fixes applied (all in `builder_emit.jl` unless noted)

1. **`cranelift_type(Union{Nothing, T})`** (the dominant blocker): a function
   whose inference-widened return type is `Union{Nothing, T}` (e.g.
   `_bump_until_n::Union{Nothing,Int64}`) threw `CompileError("unsupported type
   Union{Nothing,Int64}")` because the "all arms agree" check included Nothing
   (→TYPE_PTR) and polluted the comparison. The throw made recursive callee
   resolution set `got_ir=false`, so the mutating call was replaced by a sentinel
   that got DCE'd → `bump`/`bump_trivia` were silent no-ops → the parser peeks
   >100k times and trips `_parser_stuck_error`. Fix: classify by the non-Nothing
   arms only (drop the void arm), returning their agreed type. Unblocked
   compilation from ~9 to ~160 callees.

2. **Entry block can't be a branch target** (`native-builder/src/builder.rs`
   `init_entry`): Julia IR block 1 mapped to Cranelift `block0` (the entry).
   `while`-loop conditions often live in block 1 with a back-edge to themselves
   (`parse_chain`, `parse_generator`, `parse_decl_with_initial_ex`), so the
   back-edge jumped to the entry → verifier error "invalid reference to entry
   block block0" → trap stub. Fix: `init_entry` now creates a synthetic entry
   holding the function params and immediately `jump block0`, so `block0` is a
   normal branch-targetable block. (Julia block 1 has no phi nodes in these
   cases — the jump passes no args; param SSA values stay valid since entry
   dominates.)

3. **getfield Case 3b for >8-byte bitstypes** (`emit_struct_getfield`): the old
   Case 3b did `ushr(obj_id, off*8)` treating `obj_id` as inline register bits.
   But a >8-byte bitstype (`SyntaxToken`=12B, `RawGreenNode`=12B,
   `Tuple{Bool,Bool,SyntaxToken}`=16B) is a **heap pointer** (emit_new /
   emit_core_tuple heap-allocate it; vector loads return the pointer too).
   `ushr(heap_ptr, 32)` → garbage. This made `kind(peek_dotted_op_token(ps)[3])`
   return a corrupt SyntaxToken → `parse_LtoR` looped forever on `is_op(tk)`.
   Fix: for `isbitstype(T) && sizeof(T)>8`, load the field from
   `obj_id + fieldoffset` (memory load, like Case 4).

4. **`emit_core_tuple` field offsets**: it computed offsets with
   `align = sizeof(ET)`, but Julia's real layout aligns each field to its
   *natural* alignment (SyntaxToken: sizeof 12 but 4-byte alignment from its
   UInt32 field). So it stored the SyntaxToken at offset 12 while `getfield` read
   `fieldoffset`=4 → garbage pointer → SIGSEGV in `kind(r[3])`. Fix: use Julia's
   real `fieldoffset(tuple_type, i)` and `sizeof(tuple_type)` so store offsets
   match load offsets (with a pointer-width fallback for non-concrete tuples).

5. **Stub removal** (the architecture fix above).

6. **`emit_isa` compile-time short-circuit for concrete value types**: when `x`'s
   inferred type is concrete, `isa(x, T)` is statically `value_type <: target_type`
   — emit it as a constant instead of doing the runtime type-tag load (which
   assumes `x` is a heap pointer). Added at the top of `emit_isa`, guarded on
   `isconcretetype(val_T)`. Fixes `isa(scalar, HeapType)` derefs (e.g. a Kind
   register) that appeared in `in(Kind, Tuple{Kind})`'s 3-valued lowering. (NOTE:
   `in(Kind, Tuple{Kind})` only derefs when the tuple element is a NON-CONST
   global typed `Any`; the parser's `(K";",)` uses const elements, so `in` itself
   is fine there — the deref was a test artifact.)

7. **`cranelift_type` for mixed 3+-arm Unions with a TYPE_PTR arm**:
   `Union{Nothing, T1, T2}` where one arm is TYPE_PTR (e.g. parse_unary returns
   `Union{Nothing, ParseStreamPosition(I64), RawGreenNode(TYPE_PTR)}`) still threw
   because the "any pointer arm → TYPE_PTR" check used `is_ptr_type`, which misses
   >8-byte bitstypes (RawGreenNode) that `cranelift_type` maps to TYPE_PTR. Fix:
   after the all-non-Nothing-arms-agree check, also return TYPE_PTR if ANY
   non-Nothing arm's `cranelift_type` is TYPE_PTR. Unblocked parse_unary (was
   sentinel'd + DCE'd → never invoked → output stayed 1).

8. **getfield Case 3 must exclude `cranelift_type==TYPE_PTR`**: Case 3
   (shift/mask on a register) applied to any `isbitstype && sizeof<=8` type, but
   NamedTuples are ALWAYS TYPE_PTR (heap) even when isbitstype sizeof<=8 (e.g.
   `NamedTuple{kind,flags,orig_kind,is_leaf}`=8B from `peek_behind`). Shifting a
   heap pointer gave garbage — `peek_behind(s).kind` returned the pointer bits
   (4336356744). Fix: Case 3 now requires `cranelift_type(T) != TYPE_PTR`; such
   types fall through to Case 4's memory load.

9. **Constant >8-byte bitstypes (and NamedTuples) must be emitted as rooted heap
   pointers** (`emit_constant`): `emit_constant` returned `UInt64(0)` for bitstype
   consts with `sizeof>8` (the `else raw=0` fallback). Julia constant-folds
   `RawGreenNode(...)` literals, so `push!(v, RawGreenNode(...))` stored 0 → a
   later `v[i]` read dereferenced null → SIGSEGV (the peek_behind sorter crash).
   Fix: for `sizeof>8 || NamedTuple`, emit `pointer_from_objref(Ref(val))` (the
   direct `pointer_from_objref(val)` throws for immutable bitstypes), AND **root
   the Ref** in a module-global `_ROOTED_CONST_REFS` — without rooting the GC
   reclaims the Ref after `compile_native` returns, leaving a dangling pointer
   that reads 0 at runtime.

10. **`Base.getglobal(module, :name)` (const-global access) was unsupported** →
    sentinel → `ascii_is_identifier_char[i]` (a const `Vector{Bool}` used by
    `lex_identifier`) read as garbage. Fix: handle `getglobal` in `emit_globalref`
    — args[1] is a `GlobalRef` to the module (resolve via
    `getglobal(ref.mod, ref.name)`), args[2] is the `QuoteNode` name; resolve
    `getglobal(mod, name)` and `emit_constant` it.

11. **Sub-word array element load width was wrong (`emit_memoryrefget`).**
    `cranelift_type(Bool)` returns TYPE_I32 (Bool occupies an i32 register per the
    Wasm `scalar_repr` convention), but in a `Vector{Bool}` each element is **1
    byte in memory**. So `emit_memoryrefget` did `load.i32` at a 1-byte stride →
    read 4 adjacent elements (`ascii_is_identifier_char[98]` → `0x01010101`), which
    broke `lex_identifier`'s break test and made the lexer stop after one
    identifier (`next_token("a a")` → `[a, EndMarker]` instead of
    `[a,WS,a,EndMarker]`). Fix: load the **memory width** = `sizeof(elem)` bytes
    (Bool→`TYPE_I8`, UInt16→`TYPE_I16`, …; heap-pointer elements stay `TYPE_PTR`),
    then `uextend` to the register repr. **After this the lexer works.** The same
    memory-width rule should be applied to `emit_pointerset` (sub-word stores) and
    to `emit_struct_getfield` bitstype-field loads for completeness.

## The remaining end-to-end blocker

Full `parse!("1")` / `parse_eq("1")` SIGSEGVs at runtime in `__lookahead_index`
— a single bad deref of `lookahead[i]` (a `SyntaxToken` pointer). The ~75M
"allocations" in the crash report are parse_eq's ~4.7 GB / 21 s COMPILATION
(verified via `@timed`); the runtime fault is one deref, not a loop. The
identical `__lookahead_index`/peek path passes in the drain loop and in
isolation, so it is a **composition-only** state corruption — some operation in
the `parse_toplevel`→`parse_stmts`→`parse_Nary`→… descent writes a bad pointer
into `stream.lookahead` (or leaves a stale tracked element address in
`ref_tracking` after the lookahead vector's `_deletebeg!`/`_growend_internal!`
reallocation) that only the composed descent triggers.

**Next step:** differential-test `stream.lookahead`'s data pointer and length at
each peek across the descent vs the isolated drain, to find the first divergence
— i.e. where the composed run corrupts state that the isolated run doesn't.

## Other known gaps (not on the live `"1+2"` path, but worth fixing)

- **Compilation cost:** `parse_into` (full parser) allocates ~4.8 GB / 22 s.
  `Base.typejoin` ALONE is ~2.2 GB / 12 s to infer via the overlay interp, then
  fails verification (trap stub) anyway and is not on the live parse path. This
  4.8 GB × the several full-parser compiles in `test_final.jl`
  (ParseStream/parse!/build_tree/parse_into) exhausts the heap → the suite
  SIGSEGVs during GC marking (~141M objects) around the Tier-4 `parse_int_literal`
  compile. An attempt to blocklist type-system functions in `emit_invoke`'s
  recursive path was **reverted** (crashed the eDSL suite, did not reduce cost);
  doing this skip correctly is the highest-leverage next step for iteration speed.
- **Three Cranelift verifier failures → trap stubs** (all "invalid block reference
  blockN", N exists in pre-allation but isn't laid out — a goto to a block no
  instruction was emitted into): `typejoin` (block392), `parse_resword` (block1),
  `first_child_position` (block155). None SIGILL at runtime ⇒ not on the live
  path.

## Diagnostic method that worked

Differential testing: compile tiny wrappers around individual parser ops, run
native vs host, bisect. The recurring fault layers: ParseStream-method kwcalls,
`peek_dotted_op_token`'s `Tuple{Bool,Bool,SyntaxToken}` return, vector load/store
of 12-byte bitstypes, sub-word (`Bool`) array elements. Useful probes under
`NativeCodegen/test/` and `/tmp/`: `debug_parse_stmts.jl` (op-level matrix),
`debug_vecelem_push*.jl`, `debug_tok_construct.jl`, `debug_lexer*.jl`,
`debug_pdot*.jl`, `debug_emit.jl`, `debug_bun*.jl`. Dump per-fn Cranelift IR with
`NATIVE_BUILDER_DUMP_DIR=<dir>`; traces with `NCG_TRACE_SENTINEL=1` /
`NCG_TRACE_RETHROW=1` (note: a runtime SIGSEGV loses buffered stderr — use a
compile-only probe to capture sentinel sites cleanly).
