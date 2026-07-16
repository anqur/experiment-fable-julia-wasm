using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, Kind, TRIVIA_FLAG, bump, bump_invisible, peek
import Base.JuliaSyntax: parse_unary_prefix, is_reserved_word, set_numeric_flags

# After the module prelude (bump module, VERSION, parse_unary_prefix A), where is
# lookahead_index, and what token is there? Should be at the body separator trivia.
function lai_after(src::String)
    s = ParseStream(src); ps = ParseState(s)
    bump(ps, TRIVIA_FLAG)
    if is_reserved_word(peek(ps)); bump(ps)
    else
        bump_invisible(ps, Kind(46), set_numeric_flags(ps.stream.version[2] * 10))
        parse_unary_prefix(ps)
    end
    lai = Int64(s.lookahead_index)
    # peek with skip_newlines=false → the raw current token kind
    pk = Int64(reinterpret(UInt16, peek(ps)))
    return (lai, pk)
end

for src in ("module A end", "module A\nend")
    lai, pk = lai_after(src)
    println("src=", repr(src), " host: lookahead_index=", lai, " peek_kind=", pk, " (", JuliaSyntax.Kind(pk), ")")
end
flush(stdout)
c = compile_native(lai_after, Tuple{String}; name="laiu")
nf = native_callable_from_so(c, NTuple{2,Int64}, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = lai_after(src)
    println("src=", repr(src), " native: lai=", n[1], " peek=", n[2], " (", JuliaSyntax.Kind(n[2]), ")  host: lai=", h[1], " peek=", h[2],
            n == h ? "  OK" : "  MISMATCH")
end
rm(c.so_path)
