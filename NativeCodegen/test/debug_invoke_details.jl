# Debug invoke argument structure

using NativeCodegen
using Core.Compiler

function string_length_test(s::String)
    return length(s)
end

println("=== Debugging Invoke Argument Structure ===")

interp = NativeCodegen.NCGInterp()
tt = Base.signature_type(string_length_test, Tuple{String})
matches = Base._methods_by_ftype(tt, -1, interp.world)

if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]

        println("Checking invoke structure:")
        for (idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :invoke
                println("Statement $idx:")
                println("  Function: $(e.args[1])")
                println("  Arguments: $(e.args[2:end])")

                if length(e.args) >= 2
                    arg = e.args[2]
                    println("  First arg type: $(typeof(arg))")
                    println("  Is Core.Argument: $(arg isa Core.Argument)")
                    if arg isa Core.Argument
                        arg_idx = arg.n - 2 + 1
                        println("  Calculated index: $arg_idx")
                    end
                end
            end
        end
    end
end