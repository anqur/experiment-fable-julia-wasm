using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState

# Force a RUNTIME version[2] read that can't be constant-folded: branch on input
# length so the codegen can't fold ps.stream.version through.
function ver2_runtime(src::String, flag::Int)
    ps = ParseState(ParseStream(src))
    # Touch something runtime-dependent to defeat folding, then read version[2]
    x = length(src) + flag
    v = ps.stream.version[2]
    return Int64(v) + Int64(x) - Int64(x)
end

for src in ("x", "module A end"); println("host ver2_runtime: ", ver2_runtime(src, 1)); end
flush(stdout)
c = compile_native(ver2_runtime, Tuple{String,Int}; name="vr2")
nf = native_callable_from_so(c, Int64, String, Int)
for src in ("x", "module A end")
    n = nf(src, 1); h = ver2_runtime(src, 1)
    println("src=", repr(src), " native=", n, " host=", h, n==h ? " OK" : " WRONG")
end
rm(c.so_path)
