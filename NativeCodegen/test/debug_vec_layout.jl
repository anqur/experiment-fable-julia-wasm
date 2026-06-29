# Check Vector{Int64} memory layout
# Usage: julia +nightly --project=. NativeCodegen/test/debug_vec_layout.jl

println("sizeof(Vector{Int64}): ", sizeof(Vector{Int64}))
for fn in fieldnames(Vector{Int64})
    println("  field :$fn: offset=$(fieldoffset(Vector{Int64}, fn)), type=$(fieldtype(Vector{Int64}, fn))")
end

# Check MemoryRef layout
println()
println("MemoryRef{Int64}:")
println("  sizeof: ", sizeof(MemoryRef{Int64}))
for fn in fieldnames(MemoryRef{Int64})
    println("  field :$fn: offset=$(fieldoffset(MemoryRef{Int64}, fn)), type=$(fieldtype(MemoryRef{Int64}, fn))")
end
