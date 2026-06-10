# Mirrors of the wasmtime C API ABI structs (verified against wasmtime v45.0.1
# with a compiled C probe; see test/abi_probe.c). All sizes/alignments below
# are load-bearing for ccall correctness.

# wasmtime_valkind_t
const WASMTIME_I32 = 0x00
const WASMTIME_I64 = 0x01
const WASMTIME_F32 = 0x02
const WASMTIME_F64 = 0x03
const WASMTIME_V128 = 0x04
const WASMTIME_FUNCREF = 0x05
const WASMTIME_EXTERNREF = 0x06
const WASMTIME_ANYREF = 0x07
const WASMTIME_EXNREF = 0x08

# wasm_valkind_t (wasm.h, used for wasm_valtype_t when building functypes)
const WASM_I32 = 0x00
const WASM_I64 = 0x01
const WASM_F32 = 0x02
const WASM_F64 = 0x03
const WASM_EXTERNREF = 0x80
const WASM_FUNCREF = 0x81

# wasmtime_extern_kind_t
const WASMTIME_EXTERN_FUNC = 0x00
const WASMTIME_EXTERN_GLOBAL = 0x01
const WASMTIME_EXTERN_TABLE = 0x02
const WASMTIME_EXTERN_MEMORY = 0x03
const WASMTIME_EXTERN_SHAREDMEMORY = 0x04
const WASMTIME_EXTERN_TAG = 0x05

"""24-byte payload union of `wasmtime_val_t`/`wasmtime_extern_t` (align 8)."""
struct ValUnion
    a::UInt64
    b::UInt64
    c::UInt64
end
ValUnion() = ValUnion(0, 0, 0)

"""`wasmtime_val_t`: kind byte at offset 0, payload union at offset 8; 32 bytes."""
struct CVal
    kind::UInt8
    _pad1::UInt8
    _pad2::UInt16
    _pad3::UInt32
    of::ValUnion
end
CVal(kind::Integer, of::ValUnion) = CVal(UInt8(kind), 0, 0, 0, of)
CVal() = CVal(WASMTIME_I32, ValUnion())

"""`wasmtime_func_t`: { store_id::UInt64, private::Ptr }; 16 bytes."""
struct CFunc
    store_id::UInt64
    private::Ptr{Cvoid}
end
CFunc() = CFunc(0, C_NULL)

"""`wasmtime_instance_t`: { store_id::UInt64, private::Csize_t }; 16 bytes."""
struct CInstance
    store_id::UInt64
    private::Csize_t
end
CInstance() = CInstance(0, 0)

"""
`wasmtime_anyref_t` / `wasmtime_externref_t` / `wasmtime_exnref_t`:
{ store_id::UInt64, p1::UInt32, p2::UInt32, p3::Ptr }; 24 bytes. These are
*rooted* GC handles that must be unrooted explicitly.
"""
struct CRef
    store_id::UInt64
    p1::UInt32
    p2::UInt32
    p3::Ptr{Cvoid}
end
CRef() = CRef(0, 0, 0, C_NULL)

"""`wasmtime_extern_t`: kind byte at offset 0, 24-byte union at offset 8; 32 bytes."""
struct CExtern
    kind::UInt8
    _pad1::UInt8
    _pad2::UInt16
    _pad3::UInt32
    of::ValUnion
end
CExtern() = CExtern(0xFF, 0, 0, 0, ValUnion())

"""`wasm_byte_vec_t` / `wasm_name_t`: { size::Csize_t, data::Ptr{UInt8} }."""
struct ByteVec
    size::Csize_t
    data::Ptr{UInt8}
end
ByteVec() = ByteVec(0, C_NULL)

"""`wasm_valtype_vec_t`: { size::Csize_t, data::Ptr{Ptr} }."""
struct ValtypeVec
    size::Csize_t
    data::Ptr{Ptr{Cvoid}}
end

# Bit-packing helpers between typed payloads and the raw union words.
union_i32(v::Int32) = ValUnion(UInt64(reinterpret(UInt32, v)), 0, 0)
union_i64(v::Int64) = ValUnion(reinterpret(UInt64, v), 0, 0)
union_f32(v::Float32) = ValUnion(UInt64(reinterpret(UInt32, v)), 0, 0)
union_f64(v::Float64) = ValUnion(reinterpret(UInt64, v), 0, 0)
union_funcref(f::CFunc) = ValUnion(f.store_id, UInt64(UInt(f.private)), 0)
union_ref(r::CRef) =
    ValUnion(r.store_id, UInt64(r.p1) | (UInt64(r.p2) << 32), UInt64(UInt(r.p3)))

unwrap_i32(u::ValUnion) = reinterpret(Int32, UInt32(u.a & 0xffffffff))
unwrap_i64(u::ValUnion) = reinterpret(Int64, u.a)
unwrap_f32(u::ValUnion) = reinterpret(Float32, UInt32(u.a & 0xffffffff))
unwrap_f64(u::ValUnion) = reinterpret(Float64, u.a)
unwrap_funcref(u::ValUnion) = CFunc(u.a, Ptr{Cvoid}(UInt(u.b)))
unwrap_ref(u::ValUnion) =
    CRef(u.a, UInt32(u.b & 0xffffffff), UInt32(u.b >> 32), Ptr{Cvoid}(UInt(u.c)))

@assert sizeof(ValUnion) == 24
@assert sizeof(CVal) == 32
@assert sizeof(CExtern) == 32
@assert sizeof(CFunc) == 16
@assert sizeof(CInstance) == 16
@assert sizeof(CRef) == 24
@assert fieldoffset(CVal, 5) == 8   # CVal.of must sit at byte offset 8
