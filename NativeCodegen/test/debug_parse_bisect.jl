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

# Probe the node-count threshold: does the crash correlate with output length
# crossing a vector capacity boundary (realloc at length 17 = capacity 16→32)?
const INPUTS = [
    "a + b + c + d",
    "a + b + c + d + e",
    "a+b+c+d",
    "aa + bb + cc + dd",
    "1 + 2 + 3 + 4",
]

println("host:")
for src in INPUTS; println("  ", repr(src), " => ", parse_into(src)); end
flush(stdout)

println("\ncompile …")
comp = compile_native(parse_into, Tuple{String}; name="bisect")
nf = native_callable_from_so(comp, Int64, String)
println("native:")
for src in INPUTS
    print("  ", repr(src), " … "); flush(stdout)
    try
        v = nf(src)
        println(v == parse_into(src) ? "✅ $v" : "❌ native=$v host=$(parse_into(src))")
    catch e
        if e isa InterruptException; rethrow(); end
        println("💥 ", typeof(e))
    end
    flush(stdout)
end
rm(comp.so_path)
