using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: SyntaxToken

# Read next_byte (offset 8, UInt32) and kind (offset 0) with a VARIABLE index.
# _bump_until_n reads both; next_byte is beyond an 8-byte load.
function read_nextbyte(src::String, i::Int)
    ps = JuliaSyntax.ParseStream(src)
    JuliaSyntax.peek(ps)
    v = ps.lookahead
    @inbounds return Int64(v[i].next_byte)
end
function read_kind_at(src::String, i::Int)
    ps = JuliaSyntax.ParseStream(src)
    JuliaSyntax.peek(ps)
    v = ps.lookahead
    @inbounds return Int64(reinterpret(UInt16, kind(v[i])))
end

for (src,i) in (("module A end",2), ("module A\nend",2), ("a + b",2), ("xy",1))
    println("src=", repr(src), " i=", i, "  host next_byte=", read_nextbyte(src,i),
            "  kind=", read_kind_at(src,i))
end
flush(stdout)

c1 = compile_native(read_nextbyte, Tuple{String,Int}; name="rnb")
nf1 = native_callable_from_so(c1, Int64, String, Int)
c2 = compile_native(read_kind_at, Tuple{String,Int}; name="rka")
nf2 = native_callable_from_so(c2, Int64, String, Int)
println("--- native vs host ---")
for (src,i) in (("module A end",2), ("module A\nend",2), ("a + b",2), ("xy",1))
    nb_n = nf1(src, i); nb_h = read_nextbyte(src, i)
    ka_n = nf2(src, i); ka_h = read_kind_at(src, i)
    println("src=", repr(src), " i=", i,
            "  next_byte native=", nb_n, " host=", nb_h, nb_n==nb_h ? " OK" : " MISMATCH",
            "  | kind native=", ka_n, " host=", ka_h, ka_n==ka_h ? " OK" : " MISMATCH")
end
rm(c1.so_path); rm(c2.so_path)
