using NativeCodegen
using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS

_head_bits(h::JS.SyntaxHead) =
    Int64(reinterpret(UInt16, JS.kind(h))) | (Int64(JS.flags(h)) << 16)
function parse_into(src::String)
    ps = JS.ParseStream(src)
    JS.parse!(ps)
    out = ps.output
    i = 2
    while i <= length(out)
        n = @inbounds out[i]
        ev = (_head_bits(getfield(n, :head)),
              Int64(getfield(n, :byte_span)),
              Int64(getfield(n, :node_span_or_orig_kind)))
        i += 1
    end
    return Int64(length(out) - 1)
end

src = ARGS[1]
println("input: ", repr(src), "  host count: ", parse_into(src))
flush(stdout)

comp = compile_native(parse_into, Tuple{String}; name="one")
nf = native_callable_from_so(comp, Int64, String)
v = nf(src)
println("native count: ", v)
rm(comp.so_path)
