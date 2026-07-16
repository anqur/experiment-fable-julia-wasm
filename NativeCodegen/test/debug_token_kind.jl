using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: SyntaxToken, SyntaxHead, Kind

# Build a Vector{SyntaxToken} natively by pushing tokens, then read kind(v[1]).
# Isolates the getindex -> kind lowering for a 12-byte inline bitstype element.
function build_and_read(src::String)
    ps = JuliaSyntax.ParseStream(src)
    JuliaSyntax.peek(ps)  # force at least one token into lookahead
    v = ps.lookahead
    @inbounds return reinterpret(UInt16, kind(v[1]))
end

for src in ("module A end", "module A\nend", "a + b", "xy")
    host = build_and_read(src)
    println("src=", repr(src), "  host kind[1]=", host, " (", Kind(host), ")")
end
flush(stdout)

comp = compile_native(build_and_read, Tuple{String}; name="tkind")
nf = native_callable_from_so(comp, UInt16, String)
for src in ("module A end", "module A\nend", "a + b", "xy")
    println("src=", repr(src), "  native kind[1]=", nf(src), "  host=", build_and_read(src),
            nf(src) == build_and_read(src) ? "  OK" : "  MISMATCH")
end
rm(comp.so_path)
