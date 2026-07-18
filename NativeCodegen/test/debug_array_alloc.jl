# Verify that ObjectModule can declare imported functions and call them
# Usage: julia +nightly --project=. NativeCodegen/test/debug_array_alloc.jl

using NativeCodegen: NCGInterp

# Check what IR array allocation generates
function make_array(n::Int64)
    return Vector{Int64}(undef, n)
end

interp = NCGInterp()
tt = Base.signature_type(make_array, Tuple{Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rettype = result[1]

println("Return type: ", rettype)
println("Statements:")
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
println("CFG blocks: $(length(ir.cfg.blocks))")
for (i, b) in enumerate(ir.cfg.blocks)
    println("  block $i: stmts=$(b.stmts)")
end
