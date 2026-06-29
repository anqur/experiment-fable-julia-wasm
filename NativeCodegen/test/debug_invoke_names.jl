# Debug what function names are being extracted from invoke operations

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Function Names ===")

# Test with isempty
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

        println("Looking for invoke expressions:")
        for (idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :invoke
                println("  Statement $idx: invoke")
                invoke_func = e.args[1]

                if invoke_func isa Core.CodeInstance
                    mi_def = invoke_func.def.def
                    println("    Method: $mi_def")

                    # Test the extraction logic
                    func_name = nothing
                    if mi_def isa Method
                        func_name = mi_def.name
                    end

                    println("    Extracted func_name: $func_name")
                    println("    Is ncodeunits: $(func_name == :ncodeunits)")
                    println("    String comparison: $(func_name == :ncodeunits))")
                    println("    Direct equality: $(func_name === :ncodeunits))")
                end
            end
        end
    end
end