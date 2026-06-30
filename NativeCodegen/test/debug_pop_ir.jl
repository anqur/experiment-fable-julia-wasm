using NativeCodegen
using NativeCodegen: WasmInterp

function dump_ir(f, argtypes, label)
    println("\n========== ", label, " ==========")
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]
    println("rettype: ", rt)
    for (i, s) in enumerate(ir.stmts)
        stmt = s[:stmt]
        println("%", i, " :: ", s[:type], "  ", stmt)
        # Extra detail for memoryrefunset! statements
        str = string(stmt)
        if occursin("unset", str) && stmt isa Expr
            println("    head=", stmt.head, "  args[1]=", repr(stmt.args[1]),
                    " (", typeof(stmt.args[1]), ")")
        end
    end
end

popone(a::Vector{Int64}) = pop!(a)
dump_ir(popone, Tuple{Vector{Int64}}, "pop!(a::Vector{Int64})")
