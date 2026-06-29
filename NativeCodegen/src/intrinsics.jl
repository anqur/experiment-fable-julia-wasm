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

# Phase 2: String intrinsics that need special handling
const STRING_INTRINSICS = Set{Symbol}([
    :sizeof, :codeunits, :ncodeunits, :string,
    :getindex, :setindex!, :unsafe_copyto!,
    :__jl_string_new, :__jl_string_len, :__jl_string_get, :__jl_string_set
])

# Phase 3: Array intrinsics that need special handling
const ARRAY_INTRINSICS = Set{Symbol}([
    :arraylen, :__arraylen, :arraysize,
    :getindex, :setindex!,
    :resize!, :push!, :append!,
    :copyto!, :unsafe_copyto!,
    :__jl_gc_alloc_array, :__jl_gc_array_len, :__jl_array_get, :__jl_array_set
])
