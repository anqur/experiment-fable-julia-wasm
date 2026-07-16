using NativeCodegen: compile_native, native_callable_from_so
import Base.JuliaSyntax as JS
import Base.JuliaSyntax.Tokenize: _kw_hash

# Compare the pointers at each level of the getfield chain
println("=== HOST pointer chain ===")
println("  _kw_hash = ", pointer_from_objref(_kw_hash))
println("  _kw_hash.keys = ", pointer_from_objref(_kw_hash.keys))
println("  _nonunique = ", pointer_from_objref(JS._nonunique_kind_names))
println("  _nonunique.dict = ", pointer_from_objref(JS._nonunique_kind_names.dict))
println("  _nonunique.dict.keys = ", pointer_from_objref(JS._nonunique_kind_names.dict.keys))
println("  _nonunique.dict.keys[1] = ", JS._nonunique_kind_names.dict.keys[1])

# Native: get the dict pointer from _nonunique_kind_names
f_dict() = pointer_from_objref(JS._nonunique_kind_names.dict)
c1 = compile_native(f_dict, Tuple{}; name="fdict")
nf1 = native_callable_from_so(c1, UInt64)
println("\n  native _nonunique.dict ptr = ", nf1())
println("  host _nonunique.dict ptr =   ", reinterpret(UInt64, f_dict()))
println("  match: ", nf1() == reinterpret(UInt64, f_dict()))
rm(c1.so_path)
