using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax.Tokenize: _kw_hash

mutable struct BoxV
    v::Vector{UInt8}
end
const BV = BoxV(UInt8[0xfc, 0xae, 0x00, 0xdf])

fbox(i::Int64) = BV.v[i]         # works
fdict(i::Int64) = _kw_hash.slots[i]  # 8-byte off

println("compiling fbox (Box.v, works)...")
c1 = compile_native(fbox, Tuple{Int64}; name="fbox")
rm(c1.so_path)
println("compiling fdict (_kw_hash.slots, broken)...")
c2 = compile_native(fdict, Tuple{Int64}; name="fdict")
rm(c2.so_path)
