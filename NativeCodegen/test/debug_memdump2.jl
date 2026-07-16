import Base.JuliaSyntax.Tokenize: _kw_hash

function dump_mem(label, mem)
    println("=== $label ===")
    println("  typeof: ", typeof(mem), "  length: ", length(mem))
    println("  pointer(mem): ", pointer(mem))
    obj = reinterpret(Ptr{Cvoid}, pointer_from_objref(mem))
    println("  pointer_from_objref: ", obj)
    for off in (0, 8, 16, 24)
        val = unsafe_load(Ptr{UInt64}(obj + off))
        println("  obj+$off = 0x", string(val, base=16))
    end
    # Find where the actual data is: scan for the known first bytes
    println("  mem[1:4] = ", mem[1:min(4,end)])
end

dump_mem("_kw_hash.slots", _kw_hash.slots)
dump_mem("_kw_hash.keys", _kw_hash.keys)
