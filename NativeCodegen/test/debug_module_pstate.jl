using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, TRIVIA_FLAG, bump, bump_invisible, peek, Kind
import Base.JuliaSyntax: parse_unary_prefix, parse_block, parse_public

# Mirror parser.jl module path exactly, stopping right before bump_closing_token.
# Returns the output node KIND list so we can see the order of block vs trivia.
function module_before_close(src::String)
    stream = ParseStream(src)
    ps = ParseState(stream)
    bump(ps, TRIVIA_FLAG)            # `module`
    bump_invisible(ps, Kind(0))      # VERSION placeholder (zero-width)
    parse_unary_prefix(ps)           # name `A`
    parse_block(ps, parse_public)    # body block
    out = stream.output
    ks = Int64[]
    for i in 1:length(out)
        h = getfield(out[i], :head)
        push!(ks, Int64(reinterpret(UInt16, JuliaSyntax.kind(h))))
    end
    return ks
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src), "  host kinds: ", module_before_close(src))
end
flush(stdout)

comp = compile_native(module_before_close, Tuple{String}; name="modbc")
nf = native_callable_from_so(comp, Vector{Int64}, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = module_before_close(src)
    println("src=", repr(src))
    println("  native: ", n)
    println("  host  : ", h, n == h ? "  OK" : "  MISMATCH")
end
rm(comp.so_path)


