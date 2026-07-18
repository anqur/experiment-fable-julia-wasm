# Dump IR for fresh array allocation to design the array-return lowering.
using NativeCodegen
using NativeCodegen: NCGInterp

function alloc_array()::Vector{Int64}
    return Int64[1, 2, 3, 4]
end

interp = NCGInterp()
tt = Base.signature_type(alloc_array, Tuple{})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)

ir, rettype = result[1]
println("Return type: ", rettype)
println("\n=== IR ===")
for (i, stmt) in enumerate(ir.stmts)
    println("%", i, " :: ", stmt[:type])
    println("    ", stmt[:stmt])
end
