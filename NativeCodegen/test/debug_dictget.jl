using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax.Tokenize: _kw_hash, simple_hash
import Base.JuliaSyntax as JS

# Runtime-constructed Dict, then get
fg_runtime(h::UInt64) = get(Dict(UInt64(2662) => JS.Kind(UInt16(18))), h, JS.Kind(UInt16(3)))
# Const Dict get (the failing case)
fg_const(h::UInt64) = get(_kw_hash, h, JS.Kind(UInt16(3)))

println("host get(runtime Dict, hash(\"if\")) = ", fg_runtime(simple_hash("if")))
println("host get(const _kw_hash, hash(\"if\")) = ", reinterpret(UInt16, fg_const(simple_hash("if"))))

c1 = compile_native(fg_runtime, Tuple{UInt64}; name="grt")
nf1 = native_callable_from_so(c1, JS.Kind, UInt64)
println("native get(runtime Dict, hash(\"if\")) = ", reinterpret(UInt16, nf1(simple_hash("if"))))
rm(c1.so_path)

c2 = compile_native(fg_const, Tuple{UInt64}; name="gco")
nf2 = native_callable_from_so(c2, JS.Kind, UInt64)
println("native get(const _kw_hash, hash(\"if\")) = ", reinterpret(UInt16, nf2(simple_hash("if"))))
rm(c2.so_path)
