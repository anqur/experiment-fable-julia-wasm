using NativeCodegen: WasmInterp
import Base.JuliaSyntax as JS
interp = WasmInterp()
tt = Base.signature_type(JS.parse!, Tuple{JS.ParseStream})
ms = Base._methods_by_ftype(tt, -1, interp.world)
mi0 = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
const FOUND = Ref{Any}(nothing)
function walk(start::Core.MethodInstance, target::Symbol, depth=0)
    start.def.name === target && (FOUND[] = start; return)
    depth > 8 && return
    r = try; Base.code_ircode_by_type(start.specTypes; world=interp.world, interp=interp)
    catch; return; end
    (isnothing(r) || isempty(r)) && return
    ir, _ = r[1]
    for s in ir.stmts
        st = s[:stmt]
        if st isa Expr && st.head == :invoke
            ci = st.args[1]
            sub = ci isa Core.MethodInstance ? ci : ci isa Core.CodeInstance ? ci.def : nothing
            isnothing(sub) || walk(sub, target, depth+1)
        end
    end
end
walk(mi0, :parse_RtoL)
tl = FOUND[]
isnothing(tl) && (println("not found"); exit())
ir, rt = only(Base.code_ircode_by_type(tl.specTypes; world=interp.world, interp=interp))
open("/tmp/parse_RtoL_ir.txt", "w") do io
    for (i, s) in enumerate(ir.stmts)
        println(io, "%", i, " :: ", s[:type], "  ", s[:stmt])
    end
end
println("wrote /tmp/parse_RtoL_ir.txt (", length(ir.stmts), " stmts)")
