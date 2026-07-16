import Base.JuliaSyntax.Tokenize: _kw_hash
import Base.JuliaSyntax as JS

# Dump the raw memory layout of a Vector to understand host vs native
function dump_vec(label, v::Vector{UInt8})
    println("=== $label ===")
    println("  typeof: ", typeof(v))
    println("  pointer(v) [data ptr]: ", pointer(v))
    println("  length: ", length(v), "  first4 data: ", v[1:min(4,end)])
    # The Vector object (JuliaArrayRepr) — pointer_from_objref gives the struct
    obj = pointer_from_objref(v)
    println("  pointer_from_objref(v): ", obj)
    # Read the struct fields: elem_ptr@0, mem_obj@8, length@16, capacity@24
    for (off, nm) in ((0, :elem_ptr), (8, :mem_obj), (16, :length), (24, :capacity))
        val = unsafe_load(Ptr{UInt64}(obj + off))
        println("  +$off $nm = 0x", string(val, base=16))
    end
    # The Memory object (mem_obj@8) — its layout
    mem = unsafe_load(Ptr{Ptr{Cvoid}}(obj + 8))
    println("  Memory obj: ", mem)
    for off in (0, 8, 16)
        val = unsafe_load(Ptr{UInt64}(mem + off))
        println("    mem+$off = 0x", string(val, base=16))
    end
end

mutable struct BoxV3; v::Vector{UInt8}; end
const BV3 = BoxV3(UInt8[0xfc, 0xae, 0x00, 0xdf])
dump_vec("Box.v (native reads CORRECTLY)", BV3.v)
dump_vec("_kw_hash.slots (native reads 8-off)", _kw_hash.slots)
