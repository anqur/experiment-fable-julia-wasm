# Compile parse_into to a FIXED .so path for standalone (pure-Rust) testing.
using NativeCodegen
import Base.JuliaSyntax as JS

_head_bits(h::JS.SyntaxHead) = Int64(reinterpret(UInt16, JS.kind(h))) | (Int64(JS.flags(h)) << 16)

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

SO = "/tmp/ncg_parse.so"
comp = compile_native(parse_into, Tuple{String}; name="parse_into")
cp(comp.so_path, SO; force=true)
println("saved: ", SO)
println("symbol: ", comp.func_name)
println("host parse_into(\"1 + 2\") = ", parse_into("1 + 2"))
println("host parse_into(\"a + b + c + d\") = ", parse_into("a + b + c + d"))
