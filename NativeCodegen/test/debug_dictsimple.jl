using NativeCodegen: compile_native, native_callable_from_so

# Simple const Dict
const D = Dict{Int64,Int64}(1 => 100, 2 => 200, 3 => 300)
fg(k::Int64) = get(D, k, Int64(-1))

println("host: get(D,1)=", get(D, 1, -1), " get(D,2)=", get(D, 2, -1), " get(D,3)=", get(D, 3, -1), " get(D,9)=", get(D, 9, -1))
c = compile_native(fg, Tuple{Int64}; name="gd")
nf = native_callable_from_so(c, Int64, Int64)
for k in (1, 2, 3, 9)
    println("  get(D,", k, ") native=", nf(k))
end
rm(c.so_path)
