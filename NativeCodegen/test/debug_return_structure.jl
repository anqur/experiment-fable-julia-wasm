# Debug return statement structure

using NativeCodegen
using NativeCodegen: NCGInterp

function test_tuple_return_debug()
    x = 1
    y = 2
    return (x, y)
end

println("Investigating return structure...")
try
    interp = NCGInterp()
    tt = Base.signature_type(test_tuple_return_debug, Tuple{})
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)

    if length(result) == 1
        ir, rettype = result[1]
        println("Return type: ", rettype)
        println("Number of statements: ", length(ir.stmts))

        for (stmt_idx, stmt) in enumerate(ir.stmts)
            e = stmt[:stmt]
            println("\nStmt $stmt_idx: ", e)

            if e isa Expr
                println("  Head: ", e.head)
                println("  Args: ", e.args)
                for (i, arg) in enumerate(e.args)
                    println("    Arg $i: ", arg, " (", typeof(arg), ")")
                end
            elseif e isa Core.ReturnNode
                println("  Is ReturnNode")
                println("  Return value: ", e.val)
                println("  Return value type: ", typeof(e.val))
                if e.val isa Core.SSAValue
                    println("  SSA ID: ", e.val.id)
                    println("  SSA statement: ", ir.stmts[e.val.id])
                end
            end
        end
    end
catch e
    println("Error: ", e)
end