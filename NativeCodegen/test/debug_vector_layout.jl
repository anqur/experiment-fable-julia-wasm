println("=== Vector memory layout investigation ===")

a = Int64[10, 20, 30]
p = pointer_from_objref(a)
println("pointer_from_objref(a) = $p")
println("sizeof(Vector{Int64}) = $(sizeof(Vector{Int64}))")
println("fieldoffset(Vector{Int64}, 1) = $(fieldoffset(Vector{Int64}, 1))")  # :ref
println("fieldoffset(Vector{Int64}, 2) = $(fieldoffset(Vector{Int64}, 2))")  # :size

# Read raw memory at the Vector pointer
println("\nRaw bytes at Vector pointer:")
for i in 0:3
    val = unsafe_load(Ptr{Int64}(p + i*8))
    println("  offset $((i*8)): $val (0x$(string(val, base=16)))")
end

# Data pointer via Base
dp = pointer(a)
println("\npointer(a) = $dp")
println("pointer(a) - pointer_from_objref(a) = $(Int64(dp) - Int64(p))")

# Read elements via data pointer
println("\nElements via pointer(a):")
for i in 1:3
    println("  [$i] = $(unsafe_load(dp, i))")
end

# MemoryRef internals
ref = a.ref
println("\ntypeof(a.ref) = $(typeof(ref))")
println("fieldnames(typeof(ref)) = $(fieldnames(typeof(ref)))")

# Memory internals
mem = ref.mem
println("typeof(ref.mem) = $(typeof(mem))")
println("mem.length = $(mem.length)")
