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

Base.Experimental.@overlay WASM_MT @noinline function Base.unsafe_copyto!(
        dest::MemoryRef{T}, src::MemoryRef{T}, n::Int64) where {T}
    return (Base.inferencebarrier(dest))::MemoryRef{T}
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
