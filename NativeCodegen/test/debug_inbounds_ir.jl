# Explore @inbounds and simpler array access patterns
# Usage: julia +nightly --project=. NativeCodegen/test/debug_inbounds_ir.jl

using NativeCodegen: NCGInterp

function inspect_ir(f, argtypes)
    interp = NCGInterp()
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
    if length(ir.cfg.blocks) > 1
        println("CFG blocks: $(length(ir.cfg.blocks))")
    end
    println()
    return ir, rettype
end

# === 1. @inbounds a[i] ===

println("="^60)
println("1. @inbounds getidx")
println("="^60)

function inb_getidx(a::Vector{Int64}, i::Int64)
    @inbounds r = a[i]
    return r
end
inspect_ir(inb_getidx, Tuple{Vector{Int64}, Int64})

# === 2. unsafe_load on data pointer ===

println("="^60)
println("2. pointer-based access")
println("="^60)

function ptr_getidx(a::Vector{Int64}, i::Int64)
    p = pointer(a)
    return unsafe_load(p, i)
end
inspect_ir(ptr_getidx, Tuple{Vector{Int64}, Int64})

# === 3. arraylen via Core — what does it lower to?

println("="^60)
println("3. arraylen(a) with explicit type")
println("="^60)

function arrlen_typed(a::Vector{Int64})::Int64
    return Core.arraylen(a)
end
inspect_ir(arrlen_typed, Tuple{Vector{Int64}})

# === 4. Check if MemoryRef is bitstype ===

println("="^60)
println("4. MemoryRef properties")
println("="^60)

println("MemoryRef{Int64} isbitstype: ", isbitstype(MemoryRef{Int64}))
println("MemoryRef{Int64} ismutable: ", Base.ismutabletype(MemoryRef{Int64}))
println("sizeof(MemoryRef{Int64}): ", sizeof(MemoryRef{Int64}))
println("fieldnames: ", fieldnames(MemoryRef{Int64}))
for (i, fn) in enumerate(fieldnames(MemoryRef{Int64}))
    println("  field :$(fn): fieldoffset=$(fieldoffset(MemoryRef{Int64}, fn)), fieldtype=$(fieldtype(MemoryRef{Int64}, fn))")
end

# === 5. Tuple properties ===

println()
println("="^60)
println("5. Tuple{Int64} properties")
println("="^60)

println("Tuple{Int64} isbitstype: ", isbitstype(Tuple{Int64}))
println("sizeof(Tuple{Int64}): ", sizeof(Tuple{Int64}))
println("fieldoffset 1: ", fieldoffset(Tuple{Int64}, 1))

println()
println("Done.")
