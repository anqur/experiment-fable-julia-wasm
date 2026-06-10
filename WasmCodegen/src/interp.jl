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

# utf8proc-backed character predicates: pure-Julia semantic overlays via
# UnicodeNext + the charmap.jl port of julia_extensions.c — these compile
# INTO wasm, so no host-side unicode support is needed. (Character classes
# of codepoints assigned after UnicodeNext's data version may differ from
# the running Julia's utf8proc; the port logic itself is validated exact.)
Base.Experimental.@overlay WASM_MT Base.is_id_start_char(c::Char) =
    wasm_id_start_char(UInt32(c))

Base.Experimental.@overlay WASM_MT Base.is_id_char(c::Char) =
    wasm_id_char(UInt32(c))

Base.Experimental.@overlay WASM_MT Base.Unicode.category_code(c::Char) =
    Int32(Base.ismalformed(c) ? 31 : UnicodeNext.category_code(UInt32(c)))

Base.Experimental.@overlay WASM_MT Base.Unicode.category_code(x::Integer) =
    Int32(UnicodeNext.category_code(x))

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

Base.Experimental.@overlay WASM_MT function Base.Unicode.isgraphemebreak!(
        state::Ref{Int32}, c1::AbstractChar, c2::AbstractChar)
    if Base.ismalformed(c1) || Base.ismalformed(c2)
        state[] = 0
        return true
    end
    return UnicodeNext.grapheme_break_stateful(UInt32(c1), UInt32(c2), state)
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
    INTERCEPTS[_overlay_method(Base.unsafe_copyto!,
                               Tuple{MemoryRef{T},MemoryRef{T},Int64} where {T})] =
        InterceptSpec(:custom, Base.unsafe_copyto!, emit_memref_copy!)
    return nothing
end
