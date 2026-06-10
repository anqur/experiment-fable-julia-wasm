# Mapping from Julia types to wasm value representations.
#
# Scalars are stored in i32/i64/f32/f64. Sub-word integers (Int8/16, UInt8/16)
# live in i32 with a normalization discipline: signed values are kept
# sign-extended, unsigned values zero-extended; arithmetic renormalizes.

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

"""Scalar representation for a Julia type, or `nothing` if not a scalar."""
scalar_repr(@nospecialize T) = get(_SCALAR_REPRS, T, nothing)

"""Ghost types carry no runtime data (singletons such as `nothing`, functions)."""
isghost(@nospecialize T) = T !== Union{} && Base.issingletontype(T)

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
    T === Char && return reinterpret(Char, UInt32(reinterpret(UInt32, Int32(v))))
    r = scalar_repr(T)
    r.isfloat && return T(v)
    # integers arrive as Int32/Int64; wrap to the logical width/signedness
    return v % T
end

"""Convert a Julia scalar to what the wasm boundary expects."""
function to_wire(@nospecialize(T), v)
    T === Bool && return Int32(v::Bool)
    T === Char && return reinterpret(Int32, UInt32(v::Char))
    r = scalar_repr(T)
    r === nothing && throw(CompileError("unsupported boundary type $T"))
    r.isfloat && return T(v)
    r.vt == I64 && return v isa UInt64 ? reinterpret(Int64, v) : Int64(v)
    return v isa UInt32 ? reinterpret(Int32, v) : Int32(v)
end
