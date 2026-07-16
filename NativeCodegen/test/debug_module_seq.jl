using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, TRIVIA_FLAG, bump, bump_trivia, peek, bump_invisible,
                        Kind

# Reproduce the EXACT module-path sequence from parser.jl:2155-2175
#   bump(module, TRIVIA_FLAG)
#   bump_invisible(VERSION, ...)
#   parse_unary_prefix(ps)        # parses the name A
#   parse_block -> parse_Nary -> bump_trivia(ps) ; peek(ps)   # body
#   bump_closing_token checks peek(ps) == K"end"
function module_peek_after_body(src::String)
    ps = ParseStream(src)
    bump(ps, TRIVIA_FLAG)                       # bump `module`
    bump_invisible(ps, K"VERSION")              # zero-width VERSION
    # parse the name like parse_unary_prefix would (just bump the identifier)
    bump(ps, TRIVIA_FLAG)                       # bump `A`
    bump_trivia(ps)                             # parse_Nary line 396, skip_newlines=true
    return Int64(reinterpret(UInt16, peek(ps))) # should be K"end"=35
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src), "  host peek=", module_peek_after_body(src),
            " (", Kind(module_peek_after_body(src)), ")")
end
flush(stdout)

comp = compile_native(module_peek_after_body, Tuple{String}; name="modpeek")
nf = native_callable_from_so(comp, Int64, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = module_peek_after_body(src)
    println("src=", repr(src), "  native=", n, " (", Kind(n), ")  host=", h,
            n == h ? "  OK" : "  MISMATCH")
end
rm(comp.so_path)
