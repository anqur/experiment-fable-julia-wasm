using NativeCodegen: CC, WasmInterp
import Base.JuliaSyntax as JS

const INTERP = WasmInterp()

T = Float32
f = JS.parse_float_literal
# Build the concrete signature tuple type directly (T is bound)
tt = Tuple{typeof(f), Type{T}, String, Int, Int}
ms = Base._methods_by_ftype(tt, -1, INTERP.world)
println("n methods: ", length(ms))
mi = CC.specialize_method(ms[1].method, tt, Core.svec())
ircode = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
ir, ret = ircode[1]

println("=== CFG blocks ===")
for (i, b) in enumerate(ir.cfg.blocks)
    println("block $i: preds=", b.preds, " succs=", b.succs)
end

println("\n=== STMTS (first 80) ===")
for (si, s) in enumerate(ir.stmts)
    si > 80 && break
    println("si=$si typ=", s[:type], " stmt=", s[:stmt])
end
