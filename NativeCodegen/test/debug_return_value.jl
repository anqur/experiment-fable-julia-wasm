# Debug return value resolution

using NativeCodegen
using Core.Compiler

println("=== Debugging Return Value Resolution ===")

function string_length_field(s::String)
    l = getfield(s, :length)
    return l
end

interp = NativeCodegen.NCGInterp()
tt = Base.signature_type(string_length_field, Tuple{String})
matches = Base._methods_by_ftype(tt, -1, interp.world)

if matches !== nothing
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    if !isempty(result)
        ir, rettype = result[1]

        println("IRCode statements:")
        for (idx, stmt) in enumerate(ir.stmts)
            println("  $idx: $(stmt[:stmt])")
        end

        println("\nTerminators:")
        cfg = ir.cfg
        for (bi, block) in enumerate(cfg.blocks)
            lst = ir.stmts[last(block.stmts)][:stmt]
            println("  Block $bi: $lst")
            if lst isa Core.ReturnNode
                println("    ReturnNode val: $(try lst.val catch; "nothing" end)")
            end
        end
    end
end