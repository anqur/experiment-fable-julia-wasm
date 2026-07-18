using NativeCodegen: NCGInterp
import Base.JuliaSyntax as JS

interp = NCGInterp()
const SITES = Function[]
const SEEN = Set{Core.MethodInstance}()

function walk(mi::Core.MethodInstance, depth=0)
    mi in SEEN && return
    push!(SEEN, mi)
    depth > 8 && return
    r = try
        Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    catch; return; end
    (isnothing(r) || isempty(r)) && return
    ir, rt = r[1]
    name = try; mi.def.name; catch;:?; end
    for (i, s) in enumerate(ir.stmts)
        txt = string(s[:stmt])
        if occursin("nexacterror", txt)
            println("\n>>> ", name, " (depth ", depth, ") stmt ", i, ":\n    ", txt)
            for j in max(1,i-4):i-1
                println("    ctx%", j, ": ", ir.stmts[j][:stmt])
            end
        end
    end
    # recurse into :invoke callees
    for s in ir.stmts
        st = s[:stmt]
        if st isa Expr && st.head == :invoke
            ci = st.args[1]
            sub = try
                ci isa Core.MethodInstance ? ci :
                ci isa Core.CodeInstance ? ci.def :
                nothing
            catch; nothing; end
            isnothing(sub) || walk(sub, depth+1)
        end
    end
end

# Entry: parse!(::ParseStream)
tt = Base.signature_type(JS.parse!, Tuple{JS.ParseStream})
ms = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
println("walking parse! call graph (", length(ms), " entry methods) …")
walk(mi)
println("\n\nTotal unique callees visited: ", length(SEEN))
