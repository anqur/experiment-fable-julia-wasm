using NativeCodegen
using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax.Tokenize: simple_hash, _kw_hash
import Base.JuliaSyntax as JS

f(s::String) = simple_hash(s)
println("simple_hash test:")
for kw in ("module", "begin", "if", "while", "function", "true", "xyz")
    println("  ", kw, " host=", simple_hash(kw))
end

comp = compile_native(f, Tuple{String}; name="hash")
nf = native_callable_from_so(comp, UInt64, String)
println("\nsimple_hash native vs host:")
for kw in ("module", "begin", "if", "while", "function", "true", "xyz")
    h = simple_hash(kw); n = nf(kw)
    println("  ", rpad(kw,10), " host=", h, " native=", n, "  ", h==n ? "✅" : "❌")
end
rm(comp.so_path)

# Also test the _kw_hash lookup directly
g(h::UInt64) = get(_kw_hash, h, JS.Kind(UInt16(3)))  # 3 = Identifier
println("\n_kw_hash lookup native vs host (using host simple_hash):")
comp2 = compile_native(g, Tuple{UInt64}; name="kwhash")
nf2 = native_callable_from_so(comp2, JS.Kind, UInt64)
for kw in ("module", "begin", "if", "while")
    h = simple_hash(kw)
    println("  ", rpad(kw,10), " host=", get(_kw_hash, h, JS.Kind(UInt16(3))),
            " native=", reinterpret(UInt16, nf2(h)))
end
rm(comp2.so_path)
