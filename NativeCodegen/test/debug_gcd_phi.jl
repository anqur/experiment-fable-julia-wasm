# Dump lp_gcd's IRCode to find SSA %7 and the loop-header phi structure that
# breaks get_phi_args ("SSA value %7 not found in tracking").
lp_gcd(a::Int64, b::Int64) = (while b != 0; a, b = b, a % b end; a)
ir, _ = Base.code_ircode(lp_gcd, (Int64, Int64))[1]
println("=== lp_gcd IRCode ===")
show(IOContext(stdout, :compact=>false), ir)
println("\n\n=== blocks + phis ===")
for (bi, blk) in enumerate(ir.cfg.blocks)
    println("block $bi: preds=$(blk.preds) succs=$(blk.succs)")
    for si in blk.stmts
        e = ir.stmts[si][:stmt]
        if e isa Core.PhiNode
            println("  PHI @SSA in block $bi: edges=$(Int.(e.edges)) values=", e.values)
        end
    end
end
