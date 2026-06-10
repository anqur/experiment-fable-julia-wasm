# Mapping from Julia types to wasm value representations.
#
# Scalars are stored in i32/i64/f32/f64. Sub-word integers (Int8/16, UInt8/16)
# live in i32 with a normalization discipline: signed values are kept
# sign-extended, unsigned values zero-extended; arithmetic renormalizes.
#
# Char is stored as its RAW 32-bit pattern (UTF-8 bytes left-justified) — the
# exact same representation native Julia uses — both inside wasm and on the
# wire. This makes bitcast/zext/trunc on Char identity operations and keeps
# Base's codepoint decoding (e.g. `UInt32(::Char)`) bit-faithful. Do NOT store
# the codepoint anywhere: mixing the two conventions silently corrupts every
# Char that crosses the boundary.

struct ScalarRepr
    vt::NumType      # wasm storage type
    bits::Int        # logical width (8, 16, 32, 64)
    signed::Bool
    isfloat::Bool
end

const _SCALAR_REPRS = IdDict{Type,ScalarRepr}(
    Int64   => ScalarRepr(I64, 64, true,  false),
    UInt64  => ScalarRepr(I64, 64, false, false),
    Int32   => ScalarRepr(I32, 32, true,  false),
    UInt32  => ScalarRepr(I32, 32, false, false),
    Int16   => ScalarRepr(I32, 16, true,  false),
    UInt16  => ScalarRepr(I32, 16, false, false),
    Int8    => ScalarRepr(I32, 8,  true,  false),
    UInt8   => ScalarRepr(I32, 8,  false, false),
    Bool    => ScalarRepr(I32, 1,  false, false),
    Char    => ScalarRepr(I32, 32, false, false),
    Float64 => ScalarRepr(F64, 64, true,  true),
    Float32 => ScalarRepr(F32, 32, true,  true),
)

"""
Scalar representation for a Julia type, or `nothing` if not a scalar.
Unknown primitive types (e.g. JuliaSyntax.Kind, enums' underlying bits) are
represented as unsigned integers of their width — their operations arrive via
`reinterpret`/`bitcast` to ordinary integer types, which carry the semantics.
`Ptr` is deliberately excluded (host pointers must not flow into wasm).
"""
function scalar_repr(@nospecialize T)
    r = get(_SCALAR_REPRS, T, nothing)
    r !== nothing && return r
    if T isa DataType && isprimitivetype(T) && !(T <: Ptr)
        sz = sizeof(T)
        sz == 1 && return ScalarRepr(I32, 8, false, false)
        sz == 2 && return ScalarRepr(I32, 16, false, false)
        sz == 4 && return ScalarRepr(I32, 32, false, false)
        sz == 8 && return ScalarRepr(I64, 64, false, false)
    end
    return nothing
end

"""
The type value `X` when `T` is exactly `Type{X}`, else `nothing`. Robust to
the kind of `Type{X}` (a `TypeEq` on current nightlies, not a `DataType`).
"""
function _typeval(@nospecialize T)
    (T === DataType || T === Union{}) && return nothing
    (T isa Union || T isa UnionAll || T isa TypeVar) && return nothing
    T isa Type && T <: Type || return nothing
    p = try T.parameters catch; return nothing end
    length(p) == 1 || return nothing
    p[1] isa TypeVar && return nothing
    return p[1]
end

"""
Ghost types carry no runtime data: singletons (`nothing`, functions) and
specific type objects (`Type{Int64}` — `issingletontype` is false for these,
but the value is fully determined by the type).
"""
isghost(@nospecialize T) =
    T !== Union{} && (Base.issingletontype(T) || _typeval(T) !== nothing)

"""The unique value of a ghost type."""
function ghost_instance(@nospecialize T)
    v = _typeval(T)
    v !== nothing && return v
    return T.instance
end

"""
The wasm value type carrying values of Julia type `T`, `nothing` for ghosts.
Throws `CompileError` for unsupported types.
"""
function wasm_valtype(@nospecialize T)
    isghost(T) && return nothing
    r = scalar_repr(T)
    r === nothing && throw(CompileError("unsupported Julia type $T"))
    return r.vt
end

"""Host-side value kind symbol for `T` (`:i32`/`:i64`/`:f32`/`:f64`), or `nothing`."""
function valkind_sym(@nospecialize T)
    r = scalar_repr(T)
    r === nothing && return nothing
    r.vt == I64 && return :i64
    r.vt == I32 && return :i32
    r.vt == F64 && return :f64
    return :f32
end

"""Convert a host value arriving as i32/i64/f32/f64 back to Julia type `T`."""
function from_wire(@nospecialize(T), v)
    T === Bool && return v != 0
    # Char travels as its raw bit pattern (must invert `to_wire` exactly)
    T === Char && return reinterpret(Char, UInt32(reinterpret(UInt32, Int32(v))))
    r = scalar_repr(T)
    r.isfloat && return T(v)
    if !haskey(_SCALAR_REPRS, T)
        # unknown primitive type: reinterpret from its width's unsigned bits
        r.bits == 8 && return reinterpret(T, (v % UInt8))
        r.bits == 16 && return reinterpret(T, (v % UInt16))
        r.bits == 32 && return reinterpret(T, (v % UInt32))
        return reinterpret(T, (v % UInt64))
    end
    # integers arrive as Int32/Int64; wrap to the logical width/signedness
    return v % T
end

"""Convert a Julia scalar to what the wasm boundary expects."""
function to_wire(@nospecialize(T), v)
    T === Bool && return Int32(v::Bool)
    T === Char && return reinterpret(Int32, v::Char)   # raw bits, not codepoint
    r = scalar_repr(T)
    r === nothing && throw(CompileError("unsupported boundary type $T"))
    r.isfloat && return T(v)
    if !haskey(_SCALAR_REPRS, T)
        # unknown primitive type: ship its bits zero-extended
        r.bits == 8 && return Int32(reinterpret(UInt8, v))
        r.bits == 16 && return Int32(reinterpret(UInt16, v))
        r.bits == 32 && return reinterpret(Int32, v)
        return reinterpret(Int64, v)
    end
    r.vt == I64 && return v isa UInt64 ? reinterpret(Int64, v) : Int64(v)
    return v isa UInt32 ? reinterpret(Int32, v) : Int32(v)
end
