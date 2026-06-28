# Intrinsic → CLIF lowering.
# Phase 1: intrinsic emission is in clif_emit.jl (emit_intrinsic_clif).
# Phase 2+: move the intrinsic table here and make it extensible, similar
# to WasmCodegen's INTRINSIC_HANDLERS dict but emitting CLIF ops instead
# of wasm instructions. Also handles sub-word normalization (emit_norm! etc.).
#
# For now: re-export clif_emit's intrinsic handling, which covers the
# basic arithmetic, comparison, bitwise, float, and conversion intrinsics.

# Nothing additional needed for Phase 1 — all intrinsic emission
# is in emit_intrinsic_clif in clif_emit.jl.
