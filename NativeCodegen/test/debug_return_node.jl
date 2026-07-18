# Debug ReturnNode value specifically

using NativeCodegen
using Core.Compiler

println("=== Debugging ReturnNode Value ===")

function simple_string_field(s::String)
    return getfield(s, :length)
end

interp = NativeCodegen.NCGInterp()
tt = Base.signature_type(simple_string_field, Tuple{String})
matches = Base._methods_by_ftype(tt, -1, interp.world)

if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]

        println("Checking all blocks for ReturnNode:")
        cfg = ir.cfg
        for (bi, block) in enumerate(cfg.blocks)
            last_stmt_idx = last(block.stmts)
            last_stmt = ir.stmts[last_stmt_idx][:stmt]
            println("  Block $bi: $last_stmt (type: $(typeof(last_stmt)))")

            if last_stmt isa Core.ReturnNode
                println("    Has ReturnNode!")
                println("    lst.val: $(last_stmt.val)")
                println("    lst.val type: $(typeof(last_stmt.val))")

                if last_stmt.val !== nothing
                    if last_stmt.val isa Core.SSAValue
                        println("    SSAValue id: $(last_stmt.val.id)")
                        println("    SSA stmt: $(ir.stmts[last_stmt.val.id])")
                    end
                end
            end
        end
    end
end