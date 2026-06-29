# Debug invoke handling in CLIF emission

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Handling ===")

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
                invoke_func = e.args[1]

                if invoke_func isa Core.CodeInstance
                    mi_def = invoke_func.def.def
                    println("    Function: $(mi_def)")
                    println("    Function.name: $(mi_def.name)")
                    println("    Function type: $(typeof(mi_def))")

                    # Test the logic we use in clif_emit.jl
                    func_name = nothing
                    if mi_def isa Function
                        func_name = mi_def.name
                    else
                        # Try to get the name differently
                        func_name = mi_def.name
                    end
                    println("    Extracted func_name: $func_name")
                    println("    Is _str_egal: $(func_name == :_str_egal)")
                end
            end
        end
    end
end