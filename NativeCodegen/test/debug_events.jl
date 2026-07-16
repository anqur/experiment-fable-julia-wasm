using NativeCodegen
using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS

_head_bits(h::JS.SyntaxHead) =
    Int64(reinterpret(UInt16, JS.kind(h))) | (Int64(JS.flags(h)) << 16)

# Return the full event list (head_bits, byte_span, node_span) so we can diff.
function parse_events(src::String)
    ps = JS.ParseStream(src)
    JS.parse!(ps)
    out = ps.output
    evs = Tuple{Int64,Int64,Int64}[]
    for i in 2:length(out)
        n = @inbounds out[i]
        push!(evs, (_head_bits(getfield(n, :head)),
                    Int64(getfield(n, :byte_span)),
                    Int64(getfield(n, :node_span_or_orig_kind))))
    end
    return evs
end

src = ARGS[1]
host = parse_events(src)
println("HOST events (", length(host), "):")
for e in host; println("  ", e); end

comp = compile_native(parse_events, Tuple{String}; name="events")
nf = native_callable_from_so(comp, Vector{Tuple{Int64,Int64,Int64}}, String)
native = nf(src)
println("\nNATIVE events (", length(native), "):")
for e in native; println("  ", e); end
rm(comp.so_path)
