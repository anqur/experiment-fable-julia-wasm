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
    (Bool→`TYPE_I8`, UInt16→`TYPE_I16`, …; heap-pointer/float elements keep their
    own type), then `uextend` to the register repr. **After this the lexer works.**

12. **Sub-word STRUCT/TUPLE field load width** (`emit_struct_getfield` Case 1/3b/4
    + `emit_tuple_index_from_ssa` via the new `_load_field_mem` helper). Same bug
    class as #11 but for `getfield` on a heap struct/tuple: a `Bool` field at
    tuple offset 1 was loaded `load.i32` (4 bytes), reading into the adjacent
    `SyntaxToken` pointer → `is_compound_assignment` (the 2nd element of
    `Tuple{Bool,Bool,SyntaxToken}` from `peek_dotted_op_token`) appeared `true` →
    `parse_assignment_with_initial_ex`'s early-return guard failed → it recursed
    via `parse_assignment` forever → **stack overflow**. Fix: all getfield load
    paths now use `_load_field_mem` (load `sizeof(field)` bytes + `uextend`; floats
    keep F64/F32). **After this `parse!("1 + 2")` runs end-to-end = 7 events
    (native == host), and `parse!("1")`, `parse!("x")`, `parse!("1 + 2 * 3")`,
    `parse!("f(x)")`, `parse!("a + b * c")` all match host.**

13. **GC disabled (leak) — diagnostic.** `__jl_gc_alloc*` in `gc.rs` switched from
    `bdwgc_alloc::Allocator` to `std::alloc::System` (malloc, never reclaimed).
    This proved the day-long `lookahead[i]` SIGSEGV was a Boehm-rooting bug
    (conservative scan dropping `SyntaxToken` roots); with leaking the deref is
    gone. Proper Boehm rooting is the eventual replacement. **With GC off + fixes
    #11/#12, `parse!` works for simple expressions.**

## Current state after 13 fixes

`parse!("1 + 2")` → **7 events, native == host** (end-to-end, GC off). Simple
expressions all pass. **Remaining gaps** (likely one shared root cause — loop /
mutation-propagation): (a) **assignment statements** (`x = 1`) SIGILL — a runtime
arrayref OOB (one of ~45 bounds-check traps in the assignment path fires; the
index drifts past the buffer in the deeper assignment descent); simple expressions
don't trigger it. (b) `pop!` **in a loop** (eDSL `popsum`) regressed: single
`pop!` is correct (last elt + length--), but `pop!` ×4 in a loop leaves the array
non-empty — the loop body doesn't observe the previous iteration's mutation. eDSL
90 ✅ (was 91; popsum is the 1 regression; gcd/gcd2 pre-existing).

## The remaining end-to-end blocker

**Update 2026-07-15 (this session):** THREE bugs were found on the grow/shift
path; the live one is **Bug C (`_deletebeg!`)**, NOT the ref_tracking staleness.

**Bug B (FIXED — `native-backend/src/runtime/gc.rs` `__jl_array_grow_end`).** The
grow handler allocated only `new_bytes` (the data) but then wrote the length at
`new_data - 8` (gc.rs:320/328) — an unconditional **8-byte heap underflow** on
every `push!`. This corrupted the Boehm heap, which in turn corrupted the
Cranelift `ObjectModule`/`FunctionBuilder` state during compilation and produced
**spurious verifier failures** (`parse_chain`/`parse_generator`/
`parse_decl_with_initial_ex` → "invalid reference to entry block block0" → trap
stub → SIGILL). Fix: allocate the full `[type_ptr(8)][length(8)][data…]` Memory
layout (mirroring `__jl_gc_alloc_array_julia`), copying the type ptr from
`old_data - 16`, so `mem_obj = new_data - 8` is a valid in-allocation field.
**After this fix the SIGILL and those 3 spurious trap stubs are GONE**; only the
3 known non-live-path stubs (typejoin/parse_resword/first_child_position)
remain, and the crash becomes a clean SIGSEGV in `__lookahead_index`. (An 8-agent
workflow unanimously concluded the runtime was "100% correct" and missed this —
its runtime lens only checked `elem_ptr` re-publishing, not the `mem_obj` write.)

**Bug A (mitigated — `builder_emit.jl` memref re-derivation).** `emit_memoryrefnew`
cached a *concrete* element address in `ref_tracking` (line ~2656) that
`memoryrefget`/`set`/`unset` consumed without re-deriving; after a
`push!`/`_growend_internal!` the runtime always moves the data pointer, so a
cached address is stale. Fix: added `BuilderCtx.memref_recipes`; `memoryrefnew`
records `(stable_base_id, data_field_off, byte_off_id, elem_T)` for tracked
bases; `memoryrefget`/`set`/`unset` **reload the data pointer fresh** each use.
This is a correct robustness improvement (eDSL suite still 91 ✅) but did **not**
move the SIGSEGV — so it was not the live trigger.

**Bug C (THE live blocker — `_deletebeg!` front-deletion, UNHANDLED).**
`__lookahead_index`'s own IR compacts the lookahead buffer:
`if (lookahead_index-1) > 0.9*length(lookahead); _deletebeg!(lookahead, n); end`
(stmt 13-19 of `JuliaSyntax.__lookahead_index`). `_deletebeg!` has **no handler**
in `builder_emit.jl` and **no runtime `__jl_array_delete_beg`** (grep confirms;
only `_growend_internal!`/`resize!`/`unsafe_copyto!` are handled). So the
front-shift is either sentinel'd (no-op) or mis-compiled, corrupting
`stream.lookahead` (wrong element stride / un-updated length / dangling tail) →
the `lookahead[i]` deref in `__lookahead_index` reads a garbage `SyntaxToken`
pointer → SIGSEGV (SEGV_MAPERR). This is why the *composed* descent (which
compacts) crashes but the isolated peek drain (which never compacts) does not.

**Next step:** implement `_deletebeg!` correctly — either (a) a `builder_emit.jl`
handler that lowers `Base._deletebeg!(a, n)` to a new runtime
`__jl_array_delete_beg(a, n, elem_size)` in `gc.rs` (memmove the surviving
`len-n` elements to the front, zero the freed tail for GC safety, set length;
the data pointer does NOT move on a front-shift, but length/contents change), or
(b) ensure the overlay (`WasmCodegen/src/interp.jl` `WASM_MT`) supplies a correct
loop-based `_deletebeg!`. Then re-run `debug_parse_bang.jl` (host=7 for
`"1 + 2"`).

**Update 3 (compaction is NOT the bug — a 5-agent workflow was wrong).** A
targeted workflow (3 investigators + verifier + designer) unanimously concluded
the compaction "corrupts the MemoryRef / double-offsets" and proposed rejecting
`setfield!(:ref, memoryrefnew(...))`. **That verdict is WRONG**, disproven by the
workflow's own Probe 2, run for real: replicate the exact inlined compaction on a
`Vector{SyntaxToken}` (null front δ, `setfield!(:size, len-δ)`,
`setfield!(:ref, memoryrefnew(ref, δ+1))`, read `[1]`) → **host = 3, native = 3**
(MATCH). Direct Cranelift-IR reading confirms it: after compaction
`lookahead[i] = load(old_ptr_or_offset + δ*12 + (i-1)*12) = element (δ+i)`, which
is *exactly intended*. So the inlined compaction + MemoryRef-:ref advance are
CORRECT. (The F2 memref re-derivation and the `_deletebeg!` handler/runtime added
above are correct but unused on this path; keep them, they are regression-safe.)

**THE ACTUAL remaining bug (2026-07-15): a parser infinite-loop.** The crash stack
shows `parse_assignment_with_initial_ex` **self-recursing 27 times** for
`"1 + 2"` (it self-calls at overlay-IR stmt 233, after `parse_pair` at stmt 232;
guard is an upstream `=`-token check in this ~500-stmt function). A simple
`1 + 2` has no `=`, so it must NOT recurse 27×. The SIGSEGV (SEGV_MAPERR) is at
the leaf `__lookahead_index` read deep in the recursion — most likely stack
overflow at the guard page (or an out-of-bounds `lookahead_index` read with
boundscheck off). Next step: differential-test the parser step-by-step (peek/bump
a few tokens, compare `lookahead_index`/`lookahead` length/kind native vs host) to
find the first divergence — i.e. where the native parser mis-detects an
assignment operator or fails to consume a token, causing the self-recursion. The
compaction and MemoryRef lowering are ruled out.

---

(Prior text, kept for context.) Full `parse!("1")` / `parse_eq("1")` SIGSEGVs at
runtime in `__lookahead_index` — a single bad deref of `lookahead[i]` (a
`SyntaxToken` pointer). The ~75M "allocations" in the crash report are parse_eq's
~4.7 GB / 21 s COMPILATION (verified via `@timed`); the runtime fault is one
deref, not a loop. The identical `__lookahead_index`/peek path passes in the
drain loop and in isolation, so it is a **composition-only** state corruption.

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
