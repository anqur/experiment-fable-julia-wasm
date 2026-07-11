using NativeCodegen: CC, WasmInterp
import Base.JuliaSyntax as JS
const INTERP = WasmInterp()

function dump(f, argtypes)
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, INTERP.world)
    isempty(matches) && (println("no match for $f"); return)
    mi = CC.specialize_method(matches[1].method, tt, Core.svec())
    res = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
    isempty(res) && (println("no IR for $f"); return)
    ir, ret = res[1]
    cfg = ir.cfg
    nblocks = length(cfg.blocks)
    println("=== $f  nblocks=$nblocks nstmts=$(length(ir.stmts)) ===")
    blkof = Dict{Int,Int}()
    for (bi, b) in enumerate(cfg.blocks); for si in b.stmts; blkof[si] = bi; end; end
    maxlbl = 0
    for si in 1:length(ir.stmts)
        e = ir.stmts[si][:stmt]
        curblk = get(blkof, si, -1)
        succs = curblk > 0 ? collect(cfg.blocks[curblk].succs) : Int[]
        if e isa Core.GotoNode
            l = e.label
            maxlbl = max(maxlbl, l)
            sinblk = get(blkof, l, -1)
            blk_ok = l in succs
            stmt_ok = sinblk in succs
            println("  stmt $si (block $curblk succs=$succs): GotoNode(label=$l) | as-block-idx: block $l in_succs=$blk_ok | as-stmt-idx: stmt $l→block $sinblk in_succs=$stmt_ok")
        elseif e isa Core.GotoIfNot
            d = e.dest
            maxlbl = max(maxlbl, d)
            sinblk = get(blkof, d, -1)
            blk_ok = d in succs
            stmt_ok = sinblk in succs
            println("  stmt $si (block $curblk succs=$succs): GotoIfNot(dest=$d) | as-block-idx: block $d in_succs=$blk_ok | as-stmt-idx: stmt $d→block $sinblk in_succs=$stmt_ok")
        end
    end
    println("  max label/dest = $maxlbl, nblocks = $nblocks")
    println()
end

dump(JS.parse_float_literal, Tuple{Type{Float64}, String, Int64, Int64})
