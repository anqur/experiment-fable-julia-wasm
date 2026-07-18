# Debug tuple compilation issues

using NativeCodegen
using NativeCodegen: NCGInterp

function test_tuple2_debug()
    return (1, 2)
end

println("Investigating tuple compilation...")
try
    interp = NCGInterp()
    tt = Base.signature_type(test_tuple2_debug, Tuple{})
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)

    if length(result) == 1
        ir, rettype = result[1]
        println("Return type: ", rettype)

        println("\n=== IR Statements ===")
        for (stmt_idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            println("Stmt $stmt_idx: ", e)
            if haskey(stmt, :type)
                println("  Type: ", stmt[:type])
            end
        end
    end
catch e
    println("Error during investigation: ", e)
end

println("\n=== Attempting compilation ===")
try
    result = compile_and_call(test_tuple2_debug, Tuple{Int64, Int64}, Tuple{})
    println("Result: $result")
catch e
    println("Compilation error: $e")
    bt = catch_backtrace()
    println("Backtrace:")
    for (i, line) in enumerate(bt)
        println("$i: $line")
    end
end