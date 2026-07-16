using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, SyntaxHead
import Base.JuliaSyntax: parse_toplevel

# Return the list of output node head-kind values (UInt16) so we can diff
# native vs host node-by-node and find the extra node.
_kinds(src::String) = Int[]

function tl_kinds(src::String)
    stream = ParseStream(src)
    ps = ParseState(stream)
    parse_toplevel(ps)
    out = stream.output
    ks = Int64[]
    for i in 1:length(out)
        h = getfield(out[i], :head)
        push!(ks, Int64(reinterpret(UInt16, JuliaSyntax.kind(h))))
    end
    return ks
end

for src in ("module A end", "module A\nend")
    println("src=", repr(src))
    println("  host kinds: ", tl_kinds(src))
end
flush(stdout)

# Return as a packed value for native comparison: count + sum (cheap signature)
function tl_sig(src::String)
    ks = tl_kinds(src)
    return Int64(length(ks))
end

comp = compile_native(tl_kinds, Tuple{String}; name="tlkinds")
nf = native_callable_from_so(comp, Vector{Int64}, String)
println("--- native vs host kinds ---")
for src in ("module A end", "module A\nend")
    n = nf(src); h = tl_kinds(src)
    println("src=", repr(src))
    println("  native: ", n)
    println("  host  : ", h)
end
rm(comp.so_path)
