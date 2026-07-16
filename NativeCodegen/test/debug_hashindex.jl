using NativeCodegen: compile_native, native_callable_from_so

# Replicate hashindex's idx = ((hash(key) % Int) & (sz-1)) + 1
fidx(key::Int64, sz::Int64) = ((hash(key) % Int) & Int(sz - 1)) + 1
c = compile_native(fidx, Tuple{Int64,Int64}; name="hi")
nf = native_callable_from_so(c, Int64, Int64, Int64)
println("hashindex idx (sz=4):")
for k in 0:5
    h = fidx(k, 4); n = nf(k, 4)
    println("  key=", k, " host=", h, " native=", n, "  ", h == n ? "OK" : "MISMATCH")
end
rm(c.so_path)
