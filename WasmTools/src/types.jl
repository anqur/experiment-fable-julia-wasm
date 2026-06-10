# Wasm type system (value types, heap types, composite types) following the
# WebAssembly 3.0 spec (includes GC, function references, exceptions).
#
# Encodings are stored as the s7/s33 *signed* interpretation of the binary
# bytes, so e.g. the heap type `func` (byte 0x70) has code -0x10.

"""Numeric value type (i32, i64, f32, f64) or v128. `code` is the binary byte."""
struct NumType
    code::UInt8
end

const I32 = NumType(0x7F)
const I64 = NumType(0x7E)
const F32 = NumType(0x7D)
const F64 = NumType(0x7C)
const V128 = NumType(0x7B)

"""Packed storage type for struct fields / array elements (i8, i16)."""
struct PackedType
    code::UInt8
end

const I8 = PackedType(0x78)
const I16 = PackedType(0x77)

"""
Heap type. `code >= 0` is a concrete type index into the module's type section;
`code < 0` is an abstract heap type (the s33 interpretation of its binary encoding).
"""
struct HeapType
    code::Int64
end
HeapType(x::Integer) = HeapType(Int64(x))

const NoExnHT    = HeapType(-12)  # 0x74
const NoFuncHT   = HeapType(-13)  # 0x73
const NoExternHT = HeapType(-14)  # 0x72
const NoneHT     = HeapType(-15)  # 0x71
const FuncHT     = HeapType(-16)  # 0x70
const ExternHT   = HeapType(-17)  # 0x6F
const AnyHT      = HeapType(-18)  # 0x6E
const EqHT       = HeapType(-19)  # 0x6D
const I31HT      = HeapType(-20)  # 0x6C
const StructHT   = HeapType(-21)  # 0x6B
const ArrayHT    = HeapType(-22)  # 0x6A
const ExnHT      = HeapType(-23)  # 0x69

isconcrete(ht::HeapType) = ht.code >= 0

const ABSTRACT_HEAPTYPE_NAMES = Dict{Int64,String}(
    -12 => "noexn", -13 => "nofunc", -14 => "noextern", -15 => "none",
    -16 => "func", -17 => "extern", -18 => "any", -19 => "eq",
    -20 => "i31", -21 => "struct", -22 => "array", -23 => "exn",
)

"""Reference type: `(ref ht)` (non-nullable) or `(ref null ht)`."""
struct RefType
    nullable::Bool
    ht::HeapType
end

# Common shorthands (all nullable, as in the text format shorthands).
const FuncRefT     = RefType(true, FuncHT)
const ExternRefT   = RefType(true, ExternHT)
const AnyRefT      = RefType(true, AnyHT)
const EqRefT       = RefType(true, EqHT)
const I31RefT      = RefType(true, I31HT)
const StructRefT   = RefType(true, StructHT)
const ArrayRefT    = RefType(true, ArrayHT)
const NullRefT     = RefType(true, NoneHT)
const NullFuncRefT = RefType(true, NoFuncHT)
const ExnRefT      = RefType(true, ExnHT)

"""Concrete (ref null \$i) / (ref \$i) helpers."""
typeref(idx::Integer; nullable::Bool=false) = RefType(nullable, HeapType(idx))

const ValType = Union{NumType, RefType}
const StorageType = Union{NumType, PackedType, RefType}

"""Struct field / array element type: storage type + mutability."""
struct FieldType
    type::StorageType
    mut::Bool
end
FieldType(t::StorageType) = FieldType(t, false)

struct FuncType
    params::Vector{ValType}
    results::Vector{ValType}
end
Base.:(==)(a::FuncType, b::FuncType) = a.params == b.params && a.results == b.results
Base.hash(a::FuncType, h::UInt) = hash(a.results, hash(a.params, hash(:FuncType, h)))

struct StructType
    fields::Vector{FieldType}
end
Base.:(==)(a::StructType, b::StructType) = a.fields == b.fields
Base.hash(a::StructType, h::UInt) = hash(a.fields, hash(:StructType, h))

struct ArrayType
    elem::FieldType
end

const CompositeType = Union{FuncType, StructType, ArrayType}

"""
A type-section entry: composite type with subtyping info.
`supers` are type indices of declared supertypes (at most one in the GC MVP).
"""
struct SubType
    final::Bool
    supers::Vector{UInt32}
    comp::CompositeType
end
SubType(comp::CompositeType) = SubType(true, UInt32[], comp)
Base.:(==)(a::SubType, b::SubType) =
    a.final == b.final && a.supers == b.supers && a.comp == b.comp
Base.hash(a::SubType, h::UInt) = hash(a.comp, hash(a.supers, hash(a.final, h)))

"""A recursion group: one or more mutually-recursive type definitions."""
struct RecGroup
    types::Vector{SubType}
end
RecGroup(st::SubType) = RecGroup([st])
RecGroup(ct::CompositeType) = RecGroup([SubType(ct)])
Base.:(==)(a::RecGroup, b::RecGroup) = a.types == b.types
Base.hash(a::RecGroup, h::UInt) = hash(a.types, hash(:RecGroup, h))

"""
Limits for memories/tables. `shared` maps the threads-proposal flag bit 0x02;
it is carried as a forward-compatibility extension (the library does not
otherwise support the threads proposal, and wasm 3.0 proper only defines the
max-present and address-type flag bits).
"""
struct Limits
    min::UInt64
    max::Union{Nothing,UInt64}
    shared::Bool
    idx64::Bool
end
Limits(min::Integer, max::Union{Nothing,Integer}=nothing; shared::Bool=false, idx64::Bool=false) =
    Limits(UInt64(min), max === nothing ? nothing : UInt64(max), shared, idx64)
Base.:(==)(a::Limits, b::Limits) =
    a.min == b.min && a.max == b.max && a.shared == b.shared && a.idx64 == b.idx64

struct MemoryType
    limits::Limits
end
MemoryType(min::Integer, max::Union{Nothing,Integer}=nothing; kwargs...) =
    MemoryType(Limits(min, max; kwargs...))

struct TableType
    reftype::RefType
    limits::Limits
end

struct GlobalType
    type::ValType
    mut::Bool
end

struct TagType
    typeidx::UInt32
end
