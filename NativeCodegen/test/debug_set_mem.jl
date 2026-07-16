using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS

# Test: access _nonunique_kind_names.dict.keys[1] (Memory{Kind}, UInt16)
# This isolates the Set's internal Dict Memory access.
f_keys1() = reinterpret(UInt16, JS._nonunique_kind_names.dict.keys[1])
println("host _nonunique_kind_names.dict.keys[1] = ", f_keys1())
c1 = compile_native(f_keys1, Tuple{}; name="sk1")
nf1 = native_callable_from_so(c1, UInt16, )
println("native = ", nf1(), "  ", nf1() == f_keys1() ? "OK" : "MISMATCH")
rm(c1.so_path)

# Test: _nonunique_kind_names.dict.slots[1] (Memory{UInt8})
f_slots1() = JS._nonunique_kind_names.dict.slots[1]
println("\nhost slots[1] = ", f_slots1())
c2 = compile_native(f_slots1, Tuple{}; name="ss1")
nf2 = native_callable_from_so(c2, UInt8)
println("native = ", nf2(), "  ", nf2() == f_slots1() ? "OK" : "MISMATCH")
rm(c2.so_path)

# Test: full membership check
f_in(k::UInt16) = JS.Kind(k) in JS._nonunique_kind_names
println("\nhost Kind(3) in set = ", f_in(UInt16(3)))
c3 = compile_native(f_in, Tuple{UInt16}; name="sin")
nf3 = native_callable_from_so(c3, Bool, UInt16)
for k in (UInt16(3), UInt16(70), UInt16(1))
    println("native Kind(", k, ") in set = ", nf3(k))
end
rm(c3.so_path)
