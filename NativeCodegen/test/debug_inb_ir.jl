# Debug IR for @inbounds array access test function
# Usage: julia +nightly --project=. NativeCodegen/test/debug_inb_ir.jl

using WasmCodegen: WasmInterp

function ar_inb_get(a::Vector{Int64},i::Int64)
    @inbounds r = a[i]
    return r
end

interp = WasmInterp()
tt = Base.signature_type(ar_inb_get, Tuple{Vector{Int64}, Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rettype = result[1]

println("Return type: ", rettype)
for (i, stmt) in enumerate(ir.stmts)
    println("  [$i] $(stmt[:stmt]) :: $(stmt[:type])")
    e = stmt[:stmt]
    if e isa Expr
        println("       head=$(e.head)")
        for (j, a) in enumerate(e.args)
            println("         arg$j: $(a) ($(typeof(a)))")
        end
    end
end

println()
println("CFG blocks:")
for (i, b) in enumerate(ir.cfg.blocks)
    println("  block $i: stmts=$(b.stmts) preds=$(b.preds) succs=$(b.succs)")
end
