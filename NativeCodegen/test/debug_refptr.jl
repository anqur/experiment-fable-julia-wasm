using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax.Tokenize: _kw_hash
import Base.JuliaSyntax as JS

mutable struct BoxV2
    v::Vector{UInt8}
end
const BV2 = BoxV2(UInt8[0xfc, 0xae, 0x00, 0xdf])

# Read the :ref MemoryRef's ptr_or_offset (offset 0 of the 16-byte :ref field)
# Box.v.ref (ptr_or_offset @ +0 of the Vector's :ref field, which is @ +0 of Vector)
fbox_ref() = (getfield(BV2.v, :ref) === getfield(BV2.v, :ref); pointer_from_objref(BV2.v))
fdict_ref() = pointer_from_objref(_kw_hash)

# Simpler: return the Vector's :ref as seen by reading Vector+0 natively
fbox_p0() = Core.getfield(BV2.v, :ref)
fdict_p0() = Core.getfield(_kw_hash.slots, :ref)

# Return what native gets as the "data pointer" — getfield(vec,:ref) then the
# element-1 address. We approximate by returning the :ref value's bit pattern.
# Instead, just read vec[1] and vec.ref ptr_or_offset via a reinterpret:
read_ref_po(v::Vector{UInt8}) = UInt64(pointer(v))

c = compile_native(read_ref_po, Tuple{Vector{UInt8}}; name="rp")
nfr = native_callable_from_so(c, UInt64, Vector{UInt8})
println("Box.v: pointer = ", pointer(BV2.v), " native pointer_from_objref = ", nfr(BV2.v))
println("_kw_hash.slots: pointer = ", pointer(_kw_hash.slots), " native = ", nfr(_kw_hash.slots))
rm(c.so_path)
