# Understand how compiled code accesses a const Dict, so we can carry its data
# in the .so. Probe: compile a Dict lookup, dump the IR to see which fields the
# getindex reads (slots/keys/vals/hash?) — i.e. is it the overlay's loop or a
# generic Dict getindex?
using NativeCodegen

const D = Dict('a'=>Int64(1), 'b'=>Int64(2), 'c'=>Int64(3))
dget(c::Char) = D[c]

comp = compile_native(dget, Tuple{Char}; name="dget")
SO = "/tmp/ncg_dict.so"
cp(comp.so_path, SO; force=true)
println("saved: ", SO)
# in-process check
nf = native_callable_from_so(comp, Int64, Char)
println("in-process D['b'] = ", nf('b'), " (expect 2)")
