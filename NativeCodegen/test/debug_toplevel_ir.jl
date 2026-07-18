using NativeCodegen: NCGInterp
import Base.JuliaSyntax as JS
interp = NCGInterp()
# parse_toplevel isn't directly callable; get it via the parse! call graph.
tt = Base.signature_type(JS.parse!, Tuple{JS.ParseStream})
ms = Base._methods_by_ftype(tt, -1, interp.world)
mi0 = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())

function find_mi(start::Core.MethodInstance, target_name::Symbol, depth=0)
    start.def.name === target_name && return start
    depth > 6 && return nothing
    r = try; Base.code_ircode_by_type(start.specTypes; world=interp.world, interp=interp)
    catch; return nothing; end
    (isnothing(r) || isempty(r)) && return nothing
    ir, _ = r[1]
    for s in ir.stmts
        st = s[:stmt]
        if st isa Expr && st.head == :invoke
            ci = st.args[1]
            sub = ci isa Core.MethodInstance ? ci :
                  ci isa Core.CodeInstance ? ci.def : nothing
            isnothing(sub) || (found = find_mi(sub, target_name, depth+1); isnothing(found) || return found)
        end
    end
    nothing
end

tl = find_mi(mi0, :parse_toplevel)
println("found parse_toplevel: ", tl)
isnothing(tl) && exit()
ir, rt = only(Base.code_ircode_by_type(tl.specTypes; world=interp.world, interp=interp))
open("/tmp/parse_toplevel_ir.txt", "w") do io
    for (i, s) in enumerate(ir.stmts)
        println(io, "%", i, " :: ", s[:type], "  ", s[:stmt])
    end
end
println("wrote /tmp/parse_toplevel_ir.txt  (", length(ir.stmts), " stmts)")
