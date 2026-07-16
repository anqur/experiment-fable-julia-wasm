using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, TRIVIA_FLAG, bump, bump_trivia, peek

# Mimic parse_Nary's start: bump first token, then bump_trivia, then peek.
# For "A\nend" and "A end", peek should be K"end" (35) in both.
function nary_peek(src::String)
    ps = ParseStream(src)
    bump(ps, TRIVIA_FLAG)     # bump first token (A)
    bump_trivia(ps)           # skip_newlines=true default
    return Int64(reinterpret(UInt16, peek(ps)))
end

for src in ("A\nend", "A end", "A\n B end", "A  end")
    println("src=", repr(src), "  host peek kind=", nary_peek(src), " (", JuliaSyntax.Kind(nary_peek(src)), ")")
end
flush(stdout)

comp = compile_native(nary_peek, Tuple{String}; name="narypeek")
nf = native_callable_from_so(comp, Int64, String)
println("--- native vs host ---")
for src in ("A\nend", "A end", "A\n B end", "A  end")
    n = nf(src); h = nary_peek(src)
    println("src=", repr(src), "  native=", n, " (", JuliaSyntax.Kind(n), ")  host=", h,
            n == h ? "  OK" : "  MISMATCH")
end
rm(comp.so_path)
