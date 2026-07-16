using NativeCodegen: compile_native, native_callable_from_so

# Checked UInt32 conversion: in-range succeeds, out-of-range must throw InexactError
# (via throw_inexacterror), NOT SIGILL.
chk_trunc(x::Int) = UInt32(x)

println("compiling chk_trunc …")
comp = compile_native(chk_trunc, Tuple{Int}; name="chk_trunc")
nf = native_callable_from_so(comp, UInt32, Int)

for x in (0, 5, 13, 100, typemax(UInt32), Int64(typemax(UInt32)) + 1, -1)
    print("  UInt32(", x, ") => ")
    try
        v = nf(x)
        println(reinterpret(UInt32, v), "  ✅ (no throw)")
    catch e
        println(typeof(e), ": ", sprint(showerror, e)[1:min(end,80)])
    end
    flush(stdout)
end
rm(comp.so_path)
