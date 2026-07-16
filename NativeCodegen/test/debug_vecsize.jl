using NativeCodegen: compile_native, native_callable_from_so

mutable struct Box3
    v::Vector{UInt8}
end
# 16-element Vector (same size as Dict.slots), literal construction
const B3 = Box3(UInt8[0xfc, 0xae, 0x00, 0xdf, 0x00, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
println("B3.v length = ", length(B3.v), " first4 = ", B3.v[1:4])

fg(i::Int64) = B3.v[i]
c = compile_native(fg, Tuple{Int64}; name="vs")
nf = native_callable_from_so(c, UInt8, Int64)
print("native B3.v[1:8] (16-elem): ")
for i in 1:8; print(nf(i), " "); end
println()
rm(c.so_path)
