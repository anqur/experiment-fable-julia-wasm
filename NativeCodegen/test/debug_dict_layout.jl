cb = Char(0x62)
println("reinterpret(UInt32, Char(0x62)) = 0x", string(reinterpret(UInt32, cb); base=16))
r = Ref{Char}(cb)
GC.@preserve r begin
  bs = [unsafe_load(reinterpret(Ptr{UInt8}, pointer_from_objref(r)), i) for i in 1:4]
  println("bytes of Char('b') in memory (Ref) = ", bs, " → UInt32 = 0x", string(unsafe_load(reinterpret(Ptr{UInt32}, pointer_from_objref(r))); base=16))
end
D = Dict('a' => Int64(1), 'b' => Int64(2), 'c' => Int64(3))
GC.@preserve D begin
  # Read the key at the FILLED slot 6 two ways:
  kc = unsafe_load(pointer(D.keys), 6)            # as Char
  println("unsafe_load(pointer(D.keys), 6) as Char = ", repr(kc), " (0x", string(UInt32(kc); base=16), ")")
  # And the raw UInt32 via Ptr{Char}→ same bits:
  println("D['b'] = ", D['b'], " (in-process lookup works)")
end
