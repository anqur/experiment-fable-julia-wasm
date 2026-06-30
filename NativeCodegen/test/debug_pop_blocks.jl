using NativeCodegen
using NativeCodegen: WasmInterp

function dump_blocks(f, argtypes, label)
    println("\n========== ", label, " ==========")
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    if isempty(m)
        println("  (no methods found)")
        return
    end
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]
    println("rettype: ", rt)
    cfg = ir.cfg
    for (bi, block) in enumerate(cfg.blocks)
        println("\nBlock $bi: stmts $(block.stmts), preds=$(block.preds), succs=$(block.succs)")
        for si in block.stmts
            stmt = ir.stmts[si][:stmt]
            t = ir.stmts[si][:type]
            println("  %$si :: $t  $stmt")
        end
    end
end

popone(a::Vector{Int64}) = pop!(a)
dump_blocks(popone, Tuple{Vector{Int64}}, "pop!(a)")
