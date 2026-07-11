using NativeCodegen: CC, WasmInterp
import Base.JuliaSyntax as JS

const INTERP = WasmInterp()

T = Float32
f = JS.parse_float_literal
tt = Tuple{typeof(f), Type{T}, String, Int, Int}
ms = Base._methods_by_ftype(tt, -1, INTERP.world)
mi = CC.specialize_method(ms[1].method, tt, Core.svec())
ircode = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
ir, ret = ircode[1]

# Find phi nodes with Float32 type
println("=== Phi nodes & Float-typed stmts ===")
for (si, s) in enumerate(ir.stmts)
    t = s[:type]
    st = s[:stmt]
    if t === Float32 || t === Float64
        println("si=$si typ=$t stmt=$st")
    end
    if st isa Core.PhiNode
        println("PHI si=$si typ=$t stmt=$st")
    end
end
