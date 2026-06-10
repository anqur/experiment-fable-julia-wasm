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

# String/Char formatting: pure host string -> host string (or scalar -> host
# string); keeping it opaque offloads the whole escape_string machinery.
Base.Experimental.@overlay WASM_MT @noinline Base.repr(s::String) =
    (Base.inferencebarrier(""))::String

Base.Experimental.@overlay WASM_MT @noinline Base.repr(c::Char) =
    (Base.inferencebarrier(""))::String

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

# Deprecation warnings are logging-only (and reach for invoke_in_world):
# drop them in compiled code.
Base.Experimental.@overlay WASM_MT Base.depwarn(msg, funcsym) = nothing

# --- host byte-buffer bridge ------------------------------------------------
# Some leaf operations need host C routines over a byte string built inside
# wasm (e.g. strtod for float literals). The bytes stream out through per-byte
# pushes into a host-side buffer; a parse call consumes it. The functions
# below are the host implementations AND the offload targets (the non-const
# guard keeps their bodies uncompilable, so call sites become host imports).
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

# String-backed buffers: plain GC byte arrays in wasm (the string-backing of
# Base.StringMemory/StringVector is a host allocation optimization, not
# semantics).
Base.Experimental.@overlay WASM_MT Base.StringMemory(n::Integer) =
    Memory{UInt8}(undef, Int(n))
Base.Experimental.@overlay WASM_MT Base.StringVector(n::Integer) =
    Vector{UInt8}(undef, Int(n))

# Byte-vector growth: Base's array_new_memory(::Memory{UInt8}, n) special-cases
# string-backed memory (jl_genericmemory_owner) — in wasm every Memory is a
# plain GC array, so a fresh allocation is always correct.
Base.Experimental.@overlay WASM_MT Base.array_new_memory(
        mem::Memory{UInt8}, newlen::Int) = Memory{UInt8}(undef, newlen)

# Dict lookup: Base hashes via objectid (a foreigncall) for keys without a
# specialized hash. A linear scan is hash-free and exactly equivalent — Dict
# keys are unique under isequal — and crucially also works on constant Dicts
# whose tables were built with native hash values. Read-only lookups only;
# Dict *mutation* in wasm still fails loudly via ht_keyindex2_shorthash!.
Base.Experimental.@overlay WASM_MT function Base.ht_keyindex(
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

# Byte-fill: Base's versions are memset over an unsafe pointer; a plain loop
# is wasm-expressible and equivalent.
Base.Experimental.@overlay WASM_MT function Base.fill!(
        a::Union{Memory{UInt8},Memory{Int8}}, x::Integer)
    v = convert(eltype(a), x)
    i = 1
    while i <= length(a)
        @inbounds a[i] = v
        i += 1
    end
    return a
end

Base.Experimental.@overlay WASM_MT function Base.fill!(
        a::Union{Array{UInt8},Array{Int8}}, x::Integer)
    v = convert(eltype(a), x)
    i = 1
    while i <= length(a)
        @inbounds a[i] = v
        i += 1
    end
    return a
end

# String construction primitive: copies bytes out of a Memory{UInt8} into a
# fresh wasm string (array.copy via emit_memory_to_string!). The body is a
# pure type-pinning stub — in particular it must NOT call String(v), which
# under the overlay table resolves back to the overlay below and would make
# inference conclude infinite recursion (rt Union{} -> trap).
@noinline _memory_to_string(m::Memory{UInt8}, off::Int64, n::Int64) =
    (Base.inferencebarrier(""))::String

# String construction from wasm bytes: a pure-wasm copy. Matches
# Base.String(v)'s buffer-stealing contract by emptying v.
Base.Experimental.@overlay WASM_MT function Base.String(v::Vector{UInt8})
    n = Int64(length(v))
    off = Int64(Base.memoryrefoffset(v.ref) - 1)
    s = _memory_to_string(v.ref.mem, off, n)
    resize!(v, 0)
    return s
end

# Base's ==(String,String) is a memcmp ccall; strings are GC byte arrays here
Base.Experimental.@overlay WASM_MT Base.:(==)(a::String, b::String) =
    _str_egal(a, b)

# strtod/strtof over the host buffer; status: 0 ok, 1 underflow, 2 overflow
# (the strtod ERANGE convention, as in Base.parse and JuliaSyntax)
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

"""How an overlay method lowers: a host import, a fixed engine import, or a
custom wasm sequence."""
struct InterceptSpec
    kind::Symbol      # :hostcall, :import, or :custom
    real::Any         # the native callable (for :hostcall/:import thunks)
    emit::Any         # :custom -> (fc, i, ex, mi) -> pushed::Bool
                      # :import -> (module::String, name::String)
end

const INTERCEPTS = IdDict{Method,InterceptSpec}()

"""
Register a concrete type as host/engine-resident: values flow through wasm
as opaque `externref`s and may cross the boundary directly. Used by runtime
packages (e.g. JSRuntime's `JSString`).
"""
function register_externref_type!(T::Type)
    EXTERNREF_TYPES[T] = true
    return nothing
end
const EXTERNREF_TYPES = IdDict{Type,Bool}()

"""
Lower calls to (the unique specialization of) `m` to a call of the fixed
import `mod`/`name` — e.g. a js-string builtin from "wasm:js-string". `real`
is the native implementation, bound as the import's host thunk on engines
that don't provide it natively (wasmtime); on JS engines instantiated with
`{builtins: ["js-string"]}` the engine supplies it.
"""
function register_import_intercept!(m::Method, mod::String, name::String, real)
    INTERCEPTS[m] = InterceptSpec(:import, real, (mod, name))
    return nothing
end

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
        InterceptSpec(:custom, Base.codeunit, emit_string_codeunit!)
    INTERCEPTS[_overlay_method(Base.ncodeunits, Tuple{String})] =
        InterceptSpec(:custom, Base.ncodeunits, emit_string_ncodeunits!)
    INTERCEPTS[which(_memory_to_string, Tuple{Memory{UInt8},Int64,Int64})] =
        InterceptSpec(:custom, _memory_to_string, emit_memory_to_string!)
    INTERCEPTS[_overlay_method(Base.repr, Tuple{String})] =
        InterceptSpec(:hostcall, Base.repr, nothing)
    INTERCEPTS[_overlay_method(Base.repr, Tuple{Char})] =
        InterceptSpec(:hostcall, Base.repr, nothing)
    INTERCEPTS[_overlay_method(Base.unsafe_copyto!,
                               Tuple{MemoryRef{T},MemoryRef{T},Int64} where {T})] =
        InterceptSpec(:custom, Base.unsafe_copyto!, emit_memref_copy!)
    return nothing
end
