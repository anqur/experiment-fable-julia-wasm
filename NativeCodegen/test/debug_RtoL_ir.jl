using NativeCodegen: WasmInterp
import Base.JuliaSyntax as JS
interp = WasmInterp()
# Get parse_RtoL IR directly by signature (ParseState arg), no graph walk.
tt = Base.signature_type(JS.parse_RtoL, Tuple{JS.ParseState, Any, Any, Any})
ms = Base._methods_by_ftype(tt, -1, interp.world)
println("methods: ", length(ms))
mi = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
ir, rt = only(Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp))
open("/tmp/parse_RtoL_ir.txt", "w") do io
    for (i, s) in enumerate(ir.stmts)
        println(io, "%", i, " :: ", s[:type], "  ", s[:stmt])
    end
end
println("wrote /tmp/parse_RtoL_ir.txt (", length(ir.stmts), " stmts)")
