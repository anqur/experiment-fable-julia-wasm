# Debug invoke function name detection

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Function Name ===")

function string_eq(s1::String, s2::String)
    return s1 == s2
end

interp = NativeCodegen.WasmCodegen.WasmInterp()
tt = Base.signature_type(string_eq, Tuple{String, String})
matches = Base._methods_by_ftype(tt, -1, interp.world)

if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]

        println("Looking for invoke expressions:")
        for (idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :invoke
                println("  Statement $idx: invoke")
                println("    Function type: $(typeof(e.args[1]))")
                println("    Function: $(e.args[1])")

                invoke_func = e.args[1]
                if invoke_func isa Core.CodeInstance
                    println("    CodeInstance found!")
                    println("    def: $(invoke_func.def)")
                    println("    def.def: $(invoke_func.def.def)")
                    if invoke_func.def.def isa Function
                        println("    Function name: $(invoke_func.def.def.name)")
                    end
                elseif invoke_func isa Core.GlobalRef
                    println("    GlobalRef found!")
                    println("    name: $(invoke_func.name)")
                end
            end
        end
    end
end