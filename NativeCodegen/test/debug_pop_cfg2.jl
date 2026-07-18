using NativeCodegen
using NativeCodegen: NCGInterp

function dump_cfg(f, argtypes, label)
    println("\n========== ", label, " ==========")
    interp = NCGInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]

    cfg = ir.cfg
    println("rettype: ", rt)
    for (bi, block) in enumerate(cfg.blocks)
        println("\nBlock $bi: stmts $(block.stmts), preds=$(block.preds), succs=$(block.succs)")
        for si in block.stmts
            stmt = ir.stmts[si][:stmt]
            t = ir.stmts[si][:type]
            println("  %$si :: $t  $stmt")
        end
    end
end

function pop_resize_only(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    resize!(a, n-1)
    v
end
dump_cfg(pop_resize_only, Tuple{Vector{Int64}}, "pop_resize_only CFG")
