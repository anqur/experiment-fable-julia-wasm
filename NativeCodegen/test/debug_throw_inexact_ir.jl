using NativeCodegen: WasmInterp
interp = WasmInterp()
println("===== Core.throw_inexacterror IR =====")
tt = Base.signature_type(Core.throw_inexacterror,
                         Tuple{Symbol, Type, Int64})
ms = Base._methods_by_ftype(tt, -1, interp.world)
println("methods: ", length(ms))
mi = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rt = r[1]
println("rettype: ", rt)
for (i, s) in enumerate(ir.stmts)
    println("  %", i, " :: ", s[:type], "  ", s[:stmt])
end
