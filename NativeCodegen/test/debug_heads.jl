using NativeCodegen
using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS

function heads(src::String)
    ps = JS.ParseStream(src)
    JS.parse!(ps)
    out = ps.output
    hs = Int64[]
    for i in 2:length(out)
        n = @inbounds out[i]
        push!(hs, Int64(reinterpret(UInt16, JS.kind(getfield(n, :head)))))
    end
    return hs
end

src = ARGS[1]
host = heads(src)
println("HOST (", length(host), "): ", host)

comp = compile_native(heads, Tuple{String}; name="heads")
nf = native_callable_from_so(comp, Vector{Int64}, String)
native = nf(src)
println("NATIVE (", length(native), "): ", native)
rm(comp.so_path)
