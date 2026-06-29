# Debug full invoke expression structure

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Expression Structure ===")

function string_isempty(s::String)
    return isempty(s)
end

interp = NativeCodegen.WasmCodegen.WasmInterp()
tt = Base.signature_type(string_isempty, Tuple{String})
matches = Base._methods_by_ftype(tt, -1, interp.world)

if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]
        argtypes = [String]

        println("Looking for invoke expressions:")
        for (idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :invoke
                println("  Statement $idx: invoke")
                println("    Full expression: $e")
                println("    Number of args: $(length(e.args))")

                for i in 1:length(e.args)
                    arg = e.args[i]
                    println("    args[$i]: $arg (type: $(typeof(arg)))")
                end
            end
        end

        println("\nLet's also check the SSA values:")
        for (idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :invoke
                println("  Statement $idx invoke:")
                for i in 2:length(e.args)  # Skip the function reference
                    arg = e.args[i]
                    if arg isa Core.SSAValue
                        println("    args[$i] is SSAValue id=$(arg.id)")
                        # Find what this SSA value refers to
                        if arg.id <= length(ir.stmts)
                            ref_stmt = ir.stmts[arg.id][:stmt]
                            println("      Refers to: $ref_stmt")
                        end
                    elseif arg isa Core.Argument
                        println("    args[$i] is Argument n=$(arg.n)")
                    else
                        println("    args[$i] is $arg")
                    end
                end
            end
        end
    end
end