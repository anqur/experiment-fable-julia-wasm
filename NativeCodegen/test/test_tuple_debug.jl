# Debug tuple expression structure

using NativeCodegen
using NativeCodegen: WasmInterp

function test_tuple_debug()
    return (1, 2)
end

println("Investigating tuple expression structure...")
try
    interp = WasmInterp()
    tt = Base.signature_type(test_tuple_debug, Tuple{})
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)

    if length(result) == 1
        ir, rettype = result[1]
        println("Return type: ", rettype)

        for (stmt_idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            if e isa Expr && e.head == :tuple
                println("Found tuple expression at stmt $stmt_idx")
                println("  Head: ", e.head)
                println("  Args: ", e.args)
                for (i, arg) in enumerate(e.args)
                    println("    Arg $i: ", arg)
                    println("    Type: ", ir.stmts[stmt_idx][:type])
                end
            end
        end
    end
catch e
    println("Error: ", e)
end