# The native-codegen compilation interpreter: standard inference, with a minimal
# overlay method table that replaces Base primitives whose bodies use C calls
# (utf8proc, memcmp, memset, memchr, objectid) or host-pointer tricks
# (unsafe_wrap, String memory stealing) that the emitter cannot compile.
#
# The emitter handles natively: all scalar arithmetic, control flow, string
# access (ncodeunits/codeunit/sizeof), array ops (push!/resize!/grow), and
# struct/array allocation. No overlays needed for those.

struct NCGCacheToken end

struct NCGInterp <: CC.AbstractInterpreter
    world::UInt
    inf_cache::CC.InferenceCache
end
NCGInterp(world::UInt=Base.get_world_counter()) =
    NCGInterp(world, CC.InferenceCache())

CC.InferenceParams(::NCGInterp) = CC.InferenceParams()
CC.OptimizationParams(::NCGInterp) = CC.OptimizationParams()
CC.get_inference_world(interp::NCGInterp) = interp.world
CC.get_inference_cache(interp::NCGInterp) = interp.inf_cache
CC.cache_owner(::NCGInterp) = NCGCacheToken()

Base.Experimental.@MethodTable NCG_MT

CC.method_table(interp::NCGInterp) = CC.OverlayMethodTable(interp.world, NCG_MT)

# --- Unicode predicates (utf8proc ccalls → pure-Julia) ------------------------
# Base.is_id_start_char / is_id_char / category_code / isgraphemebreak! are C
# calls into utf8proc. The emitter does not yet handle arbitrary foreign calls,
# so we replace them with pure-Julia backed by charmap.jl + vendored UnicodeNext.

Base.Experimental.@overlay NCG_MT Base.is_id_start_char(c::Char) =
    wasm_id_start_char(UInt32(c))

Base.Experimental.@overlay NCG_MT Base.is_id_char(c::Char) =
    wasm_id_char(UInt32(c))

Base.Experimental.@overlay NCG_MT Base.Unicode.category_code(c::Char) =
    Int32(Base.ismalformed(c) ? 31 : UnicodeNext.category_code(UInt32(c)))

Base.Experimental.@overlay NCG_MT Base.Unicode.category_code(x::Integer) =
    Int32(UnicodeNext.category_code(x))

Base.Experimental.@overlay NCG_MT function Base.Unicode.isgraphemebreak!(
        state::Ref{Int32}, c1::AbstractChar, c2::AbstractChar)
    if Base.ismalformed(c1) || Base.ismalformed(c2)
        state[] = 0
        return true
    end
    return UnicodeNext.grapheme_break_stateful(UInt32(c1), UInt32(c2), state)
end

# --- Memory copy (memmove ccall → type-pinning stub) --------------------------
# Base.unsafe_copyto! uses memmove; the emitter lowers this via __jl_memcpy
# when both operands are in ref_tracking. The stub pins the return type so
# inference produces a clean :invoke.

Base.Experimental.@overlay NCG_MT @noinline function Base.unsafe_copyto!(
        dest::MemoryRef{T}, src::MemoryRef{T}, n::Int64) where {T}
    return (Base.inferencebarrier(dest))::MemoryRef{T}
end

# --- Dict lookup (objectid foreigncall → linear scan) -------------------------
# Base.hash for arbitrary keys calls objectid (a foreigncall). A linear scan is
# hash-free — Dict keys are unique under isequal — and works on const Dicts.

Base.Experimental.@overlay NCG_MT function Base.ht_keyindex(
        h::Dict{K,V}, key) where {K,V}
    keys = h.keys
    i = 1
    @inbounds while i <= length(keys)
        if Base.isslotfilled(h, i) && isequal(key, keys[i])
            return i
        end
        i += 1
    end
    return -1
end

# --- String equality (memcmp ccall → loop) ------------------------------------

Base.Experimental.@overlay NCG_MT Base.:(==)(a::String, b::String) =
    _str_egal(a, b)

function _str_egal(a::String, b::String)
    na = ncodeunits(a)
    ncodeunits(b) == na || return false
    i = 1
    while i <= na
        codeunit(a, i) == codeunit(b, i) || return false
        i += 1
    end
    return true
end

# --- unsafe_wrap(Vector{UInt8}, String) ---------------------------------------
# Base's version stack-allocates via pointer_from_objref; a loop copy compiles.

Base.Experimental.@overlay NCG_MT function Base.unsafe_wrap(::Type{Vector{UInt8}},
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

# --- Byte fill (memset ccall → loop) ------------------------------------------

Base.Experimental.@overlay NCG_MT function Base.fill!(
        a::Union{Memory{UInt8},Memory{Int8}}, x::Integer)
    v = convert(eltype(a), x)
    i = 1
    while i <= length(a)
        @inbounds a[i] = v
        i += 1
    end
    return a
end

Base.Experimental.@overlay NCG_MT function Base.fill!(
        a::Union{Array{UInt8},Array{Int8}}, x::Integer)
    v = convert(eltype(a), x)
    i = 1
    while i <= length(a)
        @inbounds a[i] = v
        i += 1
    end
    return a
end

# --- String construction (host buffer stealing → loop) -------------------------
# Base.String(v::Vector{UInt8}) steals the Vector's buffer pointer. We avoid
# that by copying into a fresh allocation. _memory_to_string is a type-pinning
# stub that the emitter lowers via builder_declare_import.

@noinline _memory_to_string(m::Memory{UInt8}, off::Int64, n::Int64) =
    (Base.inferencebarrier(""))::String

Base.Experimental.@overlay NCG_MT function Base.String(v::Vector{UInt8})
    n = Int64(length(v))
    off = Int64(Base.memoryrefoffset(v.ref) - 1)
    s = _memory_to_string(v.ref.mem, off, n)
    resize!(v, 0)
    return s
end

# --- String-backed buffers (host allocation → plain GC) ------------------------
# Base's versions use jl_genericmemory_owner (a C call) for the host string
# optimization. In compiled code all Memory is GC arrays; a fresh allocation
# is correct.

Base.Experimental.@overlay NCG_MT Base.StringMemory(n::Integer) =
    Memory{UInt8}(undef, Int(n))
Base.Experimental.@overlay NCG_MT Base.StringVector(n::Integer) =
    Vector{UInt8}(undef, Int(n))
Base.Experimental.@overlay NCG_MT Base.array_new_memory(
        mem::Memory{UInt8}, newlen::Int) = Memory{UInt8}(undef, newlen)

# --- Byte search (memchr ccall → loop) ----------------------------------------

Base.Experimental.@overlay NCG_MT function Base.findnext(
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

# --- Float parsing bridge (strtod/strtof host calls) ---------------------------
# strtod/strtof are libc functions the emitter imports at .so load time.

_HB_GUARD::Bool = true
const _HOSTBUF = Ref(UInt8[])
const _HB_STATUS = Ref(Int32(0))

@noinline function _hb_reset()
    _HB_GUARD || return nothing
    empty!(_HOSTBUF[])
    return nothing
end

@noinline function _hb_push(b::UInt8)
    _HB_GUARD || return nothing
    push!(_HOSTBUF[], b)
    return nothing
end

@noinline function _hb_status()
    _HB_GUARD || return Int32(0)
    return _HB_STATUS[]
end

@noinline function _hb_string()
    _HB_GUARD || return ""
    return String(copy(_HOSTBUF[]))
end

for (fname, cfn, CT, T) in ((:_hb_parse_f64, :jl_strtod_c, Cdouble, Float64),
                            (:_hb_parse_f32, :jl_strtof_c, Cfloat, Float32))
    @eval @noinline function $fname()
        _HB_GUARD || return zero($T)
        buf = copy(_HOSTBUF[])
        push!(buf, 0x00)
        Base.Libc.errno(0)
        endptr = Ref{Ptr{UInt8}}(C_NULL)
        x = GC.@preserve buf ccall($(QuoteNode(cfn)), $CT,
                                   (Ptr{UInt8}, Ptr{Ptr{UInt8}}),
                                   pointer(buf), endptr)
        _HB_STATUS[] = Base.Libc.errno() == Base.Libc.ERANGE ?
            (abs(x) < 1 ? Int32(1) : Int32(2)) : Int32(0)
        return $T(x)
    end
end

# --- Misc ---------------------------------------------------------------------
# Deprecation warnings: drop in compiled code (dead on the parser's hot path).
Base.Experimental.@overlay NCG_MT Base.depwarn(msg, funcsym) = nothing

# --- Interception registry -----------------------------------------------------

struct InterceptSpec
    kind::Symbol
    real::Any
    emit::Any
end

const INTERCEPTS = IdDict{Method,InterceptSpec}()
const EXTERNREF_TYPES = IdDict{Type,Bool}()

function register_externref_type!(T::Type)
    EXTERNREF_TYPES[T] = true
    return nothing
end

function register_import_intercept!(m::Method, mod::String, name::String, real)
    INTERCEPTS[m] = InterceptSpec(:import, real, (mod, name))
    return nothing
end
