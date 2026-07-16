using NativeCodegen: compile_native, native_callable_from_so

# getindex on a HOST-constructed Vector{Int} (like Dict.slots)
const HOSTV = Int[10, 20, 30, 42, 99]
fi(i::Int) = HOSTV[i]
c = compile_native(fi, Tuple{Int}; name="gi")
nf = native_callable_from_so(c, Int64, Int)
println("getindex HOST Vector{Int}:")
for i in 1:5
    println("  HOSTV[", i, "] host=", HOSTV[i], " native=", nf(i),
            "  ", HOSTV[i] == nf(i) ? "OK" : "MISMATCH")
end
rm(c.so_path)

# getindex on a host Vector{UInt8} (sub-word)
const HOSTB = UInt8[1, 2, 3, 4]
fb(i::Int) = HOSTB[i]
c2 = compile_native(fb, Tuple{Int}; name="gb")
nf2 = native_callable_from_so(c2, UInt8, Int)
println("getindex HOST Vector{UInt8}:")
for i in 1:4
    println("  HOSTB[", i, "] host=", HOSTB[i], " native=", nf2(i),
            "  ", HOSTB[i] == nf2(i) ? "OK" : "MISMATCH")
end
rm(c2.so_path)
