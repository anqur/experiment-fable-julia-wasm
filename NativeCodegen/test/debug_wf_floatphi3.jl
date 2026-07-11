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

# Show stmts 140-165 and 305-330 (the strtof regions)
for (si, s) in enumerate(ir.stmts)
    (140 <= si <= 165 || 305 <= si <= 330) || continue
    println("si=$si typ=$(s[:type]) flag=$(s[:flag]) stmt=$(s[:stmt])")
end
