# Debug invoke argument types

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Argument Types ===")

function string_isempty(s::String)
    return isempty(s)
end

interp = NativeCodegen.NCGInterp()
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
                invoke_func = e.args[1]
                invoke_args = e.args[2:end]

                println("    Number of invoke args: $(length(invoke_args))")

                if invoke_func isa Core.CodeInstance
                    mi_def = invoke_func.def.def
                    if mi_def isa Method
                        func_name = mi_def.name
                        println("    Function name: $func_name")

                        # Check first argument
                        if length(invoke_args) >= 1
                            arg = invoke_args[1]
                            println("    First arg: $arg")
                            println("    First arg type: $(typeof(arg))")
                            println("    Is Core.Argument: $(arg isa Core.Argument)")

                            if arg isa Core.Argument
                                arg_idx = arg.n - 2 + 1
                                println("    Calculated arg_idx: $arg_idx")
                                println("    arg.n: $(arg.n)")
                                if arg_idx >= 1 && arg_idx <= length(argtypes)
                                    arg_type = argtypes[arg_idx]
                                    println("    Arg type: $arg_type")
                                    println("    Is String: $(arg_type === String)")
                                else
                                    println("    Arg index out of bounds")
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end