using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState

# Read ps.stream.version[2] — version is Tuple{Int64,Int64} at offset 80 (>8B bitstype, inline)
read_ver2(src::String) = Int64(ParseStream(src).version[2])
# via ParseState.stream indirection (how parse_resword accesses it)
read_ver2_ps(src::String) = Int64(ParseState(ParseStream(src)).stream.version[2])

println("host version[2] direct: ", read_ver2("x"))
println("host version[2] via ps:  ", read_ver2_ps("x"))
flush(stdout)

c1 = compile_native(read_ver2, Tuple{String}; name="rv2")
nf1 = native_callable_from_so(c1, Int64, String)
println("native version[2] direct: ", nf1("x"), "  host: ", read_ver2("x"),
        nf1("x")==read_ver2("x") ? "  OK" : "  WRONG")
rm(c1.so_path)

c2 = compile_native(read_ver2_ps, Tuple{String}; name="rv2ps")
nf2 = native_callable_from_so(c2, Int64, String)
println("native version[2] via ps:  ", nf2("x"), "  host: ", read_ver2_ps("x"),
        nf2("x")==read_ver2_ps("x") ? "  OK" : "  WRONG")
rm(c2.so_path)
