using NativeCodegen
using NativeCodegen: NCGInterp

function alloc_array()::Vector{Int64}
    return Int64[1, 2, 3, 4]
end

interp = NCGInterp()
tt = Base.signature_type(alloc_array, Tuple{})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
ir, rettype = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)[1]

println("=== CFG blocks (bi: stmts) ===")
for (bi, b) in enumerate(ir.cfg.blocks)
    println("block $bi: preds=$(b.preds) succs=$(b.succs) stmts=$(b.stmts)")
end

println("\n=== PhiNodes per block ===")
for (bi, b) in enumerate(ir.cfg.blocks)
    phis = [si for si in b.stmts if ir.stmts[si][:stmt] isa Core.PhiNode]
    if !isempty(phis)
        println("block $bi has $(length(phis)) phi(s):")
        for si in phis
            e = ir.stmts[si][:stmt]
            println("  %$si edges=$(collect(e.edges)) values=$(collect(e.values))")
        end
    end
end
