using NativeCodegen: compile_native, native_callable_from_so

mutable struct Box2
    v::Vector{UInt8}
end
# Construct via push! (resize) — like Dict.slots after rehash
const B2 = Box2(begin; v = UInt8[]; for b in (0xfc,0xae,0x00,0xdf); push!(v, b); end; v end)
println("B2.v = ", B2.v)

fg(i::Int64) = B2.v[i]
c = compile_native(fg, Tuple{Int64}; name="vr")
nf = native_callable_from_so(c, UInt8, Int64)
print("native B2.v[i] (resized): ")
for i in 1:length(B2.v); print(nf(i), " "); end
println()
rm(c.so_path)
