# Debug IR for array allocation + access
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_ir.jl

using WasmCodegen: WasmInterp

function ar_alloc(n::Int64)
    a = Vector{Int64}(undef, n)
    a[1] = 42
    @inbounds return a[1]
end

interp = WasmInterp()
tt = Base.signature_type(ar_alloc, Tuple{Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rettype = result[1]

println("Return type: ", rettype)
println("Statements:")
for (i, stmt) in enumerate(ir.stmts)
    e = stmt[:stmt]
    println("  [$i] $(e) :: $(stmt[:type])")
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
    println("  block $i: stmts=$(b.stmts)")
end
