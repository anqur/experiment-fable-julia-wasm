using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS

# Test: KSet membership check
const KS = JS.KSet"NewlineWs ;"
println("KSet type: ", typeof(KS), " isbitstype: ", Base.isbitstype(typeof(KS)), " sizeof: ", sizeof(typeof(KS)))
println("K\"NewlineWs\" in KSet (host): ", JS.Kind(2) in KS)
println("K\"end\" in KSet (host): ", JS.Kind(35) in KS)

f(k::UInt16) = JS.Kind(k) in KS
c = compile_native(f, Tuple{UInt16}; name="kset")
nf = native_callable_from_so(c, Bool, UInt16)
for k in (UInt16(2), UInt16(35), UInt16(59))  # NewlineWs, end, ';'
    println("K\"", k, "\" in KSet (native): ", nf(k), "  host: ", f(k))
end
rm(c.so_path)
