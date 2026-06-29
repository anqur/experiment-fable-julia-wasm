# Check IR for array writes and memoryrefset!
# Usage: julia +nightly --project=. NativeCodegen/test/debug_arrayset_ir.jl

using WasmCodegen: WasmInterp

function inspect_ir(f, argtypes)
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rettype = result[1]
    println("Return type: ", rettype)
    for (i, stmt) in enumerate(ir.stmts)
        println("  [$i] $(stmt[:stmt]) :: $(stmt[:type])")
        e = stmt[:stmt]
        if e isa Expr
            for (j, a) in enumerate(e.args)
                println("         arg$j: $(a) ($(typeof(a)))")
            end
        end
    end
    println()
end

# === 1. unsafe_store! ===
println("="^60)
println("1. unsafe_store! — pointer-based write")
println("="^60)

function ptr_setidx(a::Vector{Int64}, i::Int64, v::Int64)
    p = pointer(a)
    unsafe_store!(p, v, i)
    return a[i]
end
inspect_ir(ptr_setidx, Tuple{Vector{Int64}, Int64, Int64})

# === 2. memoryrefset! pattern (from a[i] = v) ===
println("="^60)
println("2. a[i] = v setindex! write pattern")
println("="^60)

function set_get(a::Vector{Int64}, i::Int64, v::Int64)
    a[i] = v
    return v
end
inspect_ir(set_get, Tuple{Vector{Int64}, Int64, Int64})

println("Done.")
