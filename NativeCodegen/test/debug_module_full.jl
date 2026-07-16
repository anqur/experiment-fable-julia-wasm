using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, TRIVIA_FLAG, EMPTY_FLAGS, bump, bump_invisible,
                        peek, Kind, emit, position, bump_closing_token
import Base.JuliaSyntax: parse_unary_prefix, parse_block, parse_public, parse_stmts, parse_toplevel

# Full module branch (parser.jl:2147-2177), then count output nodes.
function module_branch(src::String)
    stream = ParseStream(src)
    ps = ParseState(stream)
    mark = position(ps)
    bump(ps, TRIVIA_FLAG)            # `module`
    bump_invisible(ps, Kind(0))      # VERSION (zero-width)
    parse_unary_prefix(ps)           # name `A`
    parse_block(ps, parse_public)    # body
    bump_closing_token(ps, JuliaSyntax.Kind(35))  # K"end"
    emit(ps, mark, JuliaSyntax.Kind(70), EMPTY_FLAGS)  # K"module" placeholder
    return Int64(length(stream.output))
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src), "  host output=", module_branch(src))
end
flush(stdout)

comp = compile_native(module_branch, Tuple{String}; name="modfull")
nf = native_callable_from_so(comp, Int64, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = module_branch(src)
    println("src=", repr(src), "  native=", n, " host=", h, n == h ? "  OK" : "  MISMATCH <=== BUG")
end
rm(comp.so_path)
