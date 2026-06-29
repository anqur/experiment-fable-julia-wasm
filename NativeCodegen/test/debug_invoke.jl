# Debug invoke operations

using NativeCodegen
using Core.Compiler

println("=== Debugging Invoke Operations ===")

function string_length_test(s::String)
    return length(s)
end

println("1. Analyzing length(String) IRCode:")
interp = NativeCodegen.WasmCodegen.WasmInterp()
tt = Base.signature_type(string_length_test, Tuple{String})
matches = Base._methods_by_ftype(tt, -1, interp.world)
if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]
        println("IRCode statements:")
        for (idx, stmt) in enumerate(ir.stmts)
            println("$idx: $(stmt)")
            if stmt[:stmt] isa Expr
                e = stmt[:stmt]
                println("  Head: $(e.head)")
                if e.head == :invoke
                    println("  Function: $(e.args[1])")
                    println("  Arguments: $(e.args[2:end])")
                end
            end
        end
    end
end