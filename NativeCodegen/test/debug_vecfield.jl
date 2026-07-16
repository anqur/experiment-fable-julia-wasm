using NativeCodegen: compile_native, native_callable_from_so

mutable struct Box
    v::Vector{UInt8}
end
const B = Box(UInt8[0xfc, 0xae, 0x00, 0xdf])

# getfield(struct, :v) then getindex — like Dict.slots
fg(i::Int64) = B.v[i]
c = compile_native(fg, Tuple{Int64}; name="vf")
nf = native_callable_from_so(c, UInt8, Int64)
println("B.v = ", B.v)
print("native B.v[i]: ")
for i in 1:length(B.v); print(nf(i), " "); end
println()
rm(c.so_path)

# Also: return the Vector then length (does getfield give the right Vector?)
fl(i::Int64) = length(B.v)
c2 = compile_native(fl, Tuple{Int64}; name="vl")
nf2 = native_callable_from_so(c2, Int64, Int64)
println("native length(B.v) = ", nf2(0), " (host ", length(B.v), ")")
rm(c2.so_path)
