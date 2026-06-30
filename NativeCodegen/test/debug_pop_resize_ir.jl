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
        println("%", i, " :: ", s[:type], "  ", s[:stmt])
    end
end

function pop_resize_only(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    resize!(a, n-1)
    v
end
dump_ir(pop_resize_only, Tuple{Vector{Int64}}, "pop_resize_only")
