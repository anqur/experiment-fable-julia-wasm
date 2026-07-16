using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax.Tokenize: simple_hash

fh(x::UInt64) = hash(x)
c = compile_native(fh, Tuple{UInt64}; name="hu")
nf = native_callable_from_so(c, UInt64, UInt64)
for x in (simple_hash("if"), simple_hash("module"), UInt64(42), UInt64(0))
    h = hash(x); n = nf(x)
    println("  hash(", x, ") host=", h, " native=", n, "  ", h == n ? "OK" : "MISMATCH")
end
rm(c.so_path)
