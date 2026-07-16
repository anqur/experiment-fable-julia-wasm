using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState
import Base.JuliaSyntax: parse_toplevel, parse!

# parse_toplevel wraps everything (this is what parse! calls).
function tl_out(src::String)
    stream = ParseStream(src)
    ps = ParseState(stream)
    parse_toplevel(ps)
    return Int64(length(stream.output))
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src), "  host toplevel output=", tl_out(src))
end
flush(stdout)

comp = compile_native(tl_out, Tuple{String}; name="tlout")
nf = native_callable_from_so(comp, Int64, String)
println("--- native vs host ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = tl_out(src)
    println("src=", repr(src), "  native=", n, " host=", h, n == h ? "  OK" : "  MISMATCH <=== BUG")
end
rm(comp.so_path)
