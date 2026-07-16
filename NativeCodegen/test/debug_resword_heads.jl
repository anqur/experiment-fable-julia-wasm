using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState
import Base.JuliaSyntax: parse_resword

# Full head bits (kind | flags<<16) for each output node.
heads_of(out) = Int64[reinterpret(UInt16, JuliaSyntax.kind(getfield(out[i], :head))) |
                      (Int64(JuliaSyntax.flags(getfield(out[i], :head))) << 16)
                      for i in 1:length(out)]

function via_resword(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_resword(ps)
    return heads_of(s.output)
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src))
    println("  host heads: ", via_resword(src))
end
flush(stdout)

c = compile_native(via_resword, Tuple{String}; name="reswordheads")
nf = native_callable_from_so(c, Vector{Int64}, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = via_resword(src)
    println("src=", repr(src))
    println("  native: ", n)
    println("  host  : ", h, n == h ? "  OK" : "  DIFF")
end
rm(c.so_path)
