# The Wasm compilation interpreter: standard inference, but with an overlay
# method table that replaces a small set of pointer-based Base primitives with
# opaque @noinline stubs. The stubs survive optimization as `:invoke`s of the
# overlay methods, which codegen intercepts (see INTERCEPTS) and lowers to
# host imports or custom wasm sequences — *before* their raw-pointer bodies
# can be inlined into the IR.

struct WasmCacheToken end

struct WasmInterp <: CC.AbstractInterpreter
    world::UInt
    inf_cache::CC.InferenceCache
end
WasmInterp(world::UInt=Base.get_world_counter()) =
    WasmInterp(world, CC.InferenceCache())

CC.InferenceParams(::WasmInterp) = CC.InferenceParams()
CC.OptimizationParams(::WasmInterp) = CC.OptimizationParams()
CC.get_inference_world(interp::WasmInterp) = interp.world
CC.get_inference_cache(interp::WasmInterp) = interp.inf_cache
CC.cache_owner(::WasmInterp) = WasmCacheToken()

Base.Experimental.@MethodTable WASM_MT

CC.method_table(interp::WasmInterp) = CC.OverlayMethodTable(interp.world, WASM_MT)

# --- overlay stubs -------------------------------------------------------------
# Bodies are never executed; they only pin the return type. @noinline keeps the
# call sites as :invoke edges of these methods.

Base.Experimental.@overlay WASM_MT @noinline Base.codeunit(s::String, i::Int64) =
    (Base.inferencebarrier(0x00))::UInt8

Base.Experimental.@overlay WASM_MT @noinline Base.ncodeunits(s::String) =
    (Base.inferencebarrier(0))::Int64

# utf8proc-backed character predicates (C calls in Base)
Base.Experimental.@overlay WASM_MT @noinline Base.is_id_start_char(c::Char) =
    (Base.inferencebarrier(false))::Bool

Base.Experimental.@overlay WASM_MT @noinline Base.is_id_char(c::Char) =
    (Base.inferencebarrier(false))::Bool

Base.Experimental.@overlay WASM_MT @noinline Base.Unicode.category_code(c::Char) =
    (Base.inferencebarrier(Int32(0)))::Int32

Base.Experimental.@overlay WASM_MT @noinline function Base.unsafe_copyto!(
        dest::MemoryRef{T}, src::MemoryRef{T}, n::Int64) where {T}
    return (Base.inferencebarrier(dest))::MemoryRef{T}
end

# --- semantic overlays ----------------------------------------------------------
# Unlike the stubs above, these bodies are real Julia implementations that the
# compiler lowers like any other code; they replace pointer-aliasing tricks
# with wasm-expressible equivalents (valid because Strings are immutable).

Base.Experimental.@overlay WASM_MT function Base.unsafe_wrap(::Type{Vector{UInt8}},
                                                             s::String)
    n = ncodeunits(s)
    v = Vector{UInt8}(undef, n)
    i = 1
    while i <= n
        @inbounds v[i] = codeunit(s, i)
        i += 1
    end
    return v
end

# memchr-backed byte search: plain Julia scan over codeunit hostcalls
Base.Experimental.@overlay WASM_MT function Base.findnext(
        pred::Base.Fix2{typeof(==),UInt8}, a::Base.CodeUnits{UInt8,String}, i::Int64)
    n = ncodeunits(a.s)
    i < 1 && throw(BoundsError(a, i))
    i > n + 1 && throw(BoundsError(a, i))
    j = i
    while j <= n
        codeunit(a.s, j) == pred.x && return j
        j += 1
    end
    return nothing
end

# Grapheme-break detection (utf8proc, stateful via Ref{Int32}): route through a
# scalar-only helper that must NOT compile (the non-const global read pins it
# to the host; otherwise the overlay below would recurse into it).
_HOST_ONLY::Bool = true

@noinline function _grapheme_break_packed(c1::Char, c2::Char, state::Int32)
    _HOST_ONLY || return Int64(0)
    r = Ref(state)
    b = Base.Unicode.isgraphemebreak!(r, c1, c2)
    return (Int64(b) << 32) | Int64(reinterpret(UInt32, r[]))
end

Base.Experimental.@overlay WASM_MT function Base.Unicode.isgraphemebreak!(
        state::Ref{Int32}, c1::AbstractChar, c2::AbstractChar)
    packed = _grapheme_break_packed(Char(c1), Char(c2), state[])
    state[] = reinterpret(Int32, UInt32(packed & 0xffffffff))
    return (packed >> 32) != 0
end

# --- interception registry ------------------------------------------------------

"""How an overlay method lowers: a host import or a custom wasm sequence."""
struct InterceptSpec
    kind::Symbol      # :hostcall or :custom
    real::Any         # the native callable (for :hostcall thunks)
    emit::Any         # (fc, i, ex, mi) -> pushed::Bool (for :custom)
end

const INTERCEPTS = IdDict{Method,InterceptSpec}()

function _overlay_method(@nospecialize(f), argtypes::Type{<:Tuple})
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, WASM_MT, -1, Base.get_world_counter())
    (matches === nothing || length(matches) != 1) &&
        error("expected a unique overlay method for $tt")
    return matches[1].method
end

"""Register the intercept lowerings (called below; uses emitters from compiler.jl)."""
function _register_intercepts!()
    INTERCEPTS[_overlay_method(Base.codeunit, Tuple{String,Int64})] =
        InterceptSpec(:hostcall, Base.codeunit, nothing)
    INTERCEPTS[_overlay_method(Base.ncodeunits, Tuple{String})] =
        InterceptSpec(:hostcall, Base.ncodeunits, nothing)
    INTERCEPTS[_overlay_method(Base.is_id_start_char, Tuple{Char})] =
        InterceptSpec(:hostcall, Base.is_id_start_char, nothing)
    INTERCEPTS[_overlay_method(Base.is_id_char, Tuple{Char})] =
        InterceptSpec(:hostcall, Base.is_id_char, nothing)
    INTERCEPTS[_overlay_method(Base.Unicode.category_code, Tuple{Char})] =
        InterceptSpec(:hostcall, c -> Int32(Base.Unicode.category_code(c)), nothing)
    INTERCEPTS[_overlay_method(Base.unsafe_copyto!,
                               Tuple{MemoryRef{T},MemoryRef{T},Int64} where {T})] =
        InterceptSpec(:custom, Base.unsafe_copyto!, emit_memref_copy!)
    return nothing
end
