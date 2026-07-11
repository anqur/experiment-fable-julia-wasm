# Verify whether GotoNode.label / GotoIfNot.dest are STATEMENT or BLOCK indices.
using NativeCodegen: CC, WasmInterp
const INTERP = WasmInterp()

function withloop(n)
    s = 0
    i = 1
    while i <= n
        s += i
        i += 1
    end
    return s
end

function dump_ir(f, argtypes)
    res = Base.code_ircode(f, argtypes)
    ir, ret = res[1]
    cfg = ir.cfg
    println("=== $(f)  nblocks=$(length(cfg.blocks)) nstmts=$(length(ir.stmts)) ===")
    blkof = Dict{Int,Int}()
    for (bi, b) in enumerate(cfg.blocks); for si in b.stmts; blkof[si] = bi; end; end
    for (bi, b) in enumerate(cfg.blocks)
        println(" block $bi: stmts=$(collect(b.stmts)) succs=$(b.succs)")
    end
    for si in 1:length(ir.stmts)
        e = ir.stmts[si][:stmt]
        if e isa Core.GotoNode
            println("  stmt $si (in block $(blkof[si])): GotoNode(label=$(e.label))  => label is block $(get(blkof,e.label,-1))")
        elseif e isa Core.GotoIfNot
            println("  stmt $si (in block $(blkof[si])): GotoIfNot(dest=$(e.dest))  => dest is block $(get(blkof,e.dest,-1))")
        end
    end
    println()
end

dump_ir(withloop, Tuple{Int64})
dump_ir((n)->n <= 1 ? 1 : n*factorial(n-1), Tuple{Int64})
