# Check unreachable IR node type and memoryref patterns
# Usage: julia +nightly --project=. NativeCodegen/test/debug_unreachable.jl

using WasmCodegen: WasmInterp

function f(a::Vector{Int64}, i::Int64)
    return a[i]
end

interp = WasmInterp()
tt = Base.signature_type(f, Tuple{Vector{Int64}, Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, _ = result[1]

for (i, stmt) in enumerate(ir.stmts)
    e = stmt[:stmt]
    println("  [$i] type=$(typeof(e))")
    if occursin("unreachable", string(e)) || occursin("boundscheck", string(e))
        println("    -> SPECIAL: $(typeof(e))")
        if e isa Expr
            println("    head=$(e.head)")
        end
        for T in [Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.PhiNode]
            println("    isa $T: $(e isa T)")
        end
    end
end
