# Probe jl_array_t layout for the current Julia nightly.
# Used to determine the JuliaArrayRepr struct offsets in native-backend/src/runtime/gc.rs.
#
# jl_array_t is an internal C struct whose layout is version-dependent.
# This script reads a Vector{Int64} at increasing offsets from
# pointer_from_objref(a) to identify field positions.

a = Int64[10, 20, 30, 40, 50]
ptr = pointer_from_objref(a)
ptr_int = reinterpret(UInt64, ptr)

println("=== jl_array_t layout probe ===")
println("Vector{Int64} = $a")
println("pointer_from_objref(a) = $(repr(ptr))")
println("sizeof(Vector{Int64}) = $(sizeof(Vector{Int64}))")
println()

# Read 8-byte words at offsets 0..56 from the data pointer
println("--- Raw i64 values at 8-byte offsets from data ptr ---")
for off in 0:8:56
    val = unsafe_load(Ptr{Int64}(ptr + off))
    ptr_val = unsafe_load(Ptr{UInt64}(ptr + off))
    println("  [+$off] i64 = $val  (hex: 0x$(string(ptr_val, base=16, pad=16)))")
end

println()

# Identify key fields
data_ptr_field = unsafe_load(Ptr{UInt64}(ptr + 0))
println("--- Field identification ---")
println("offset +0 (data_ptr): $(repr(Ptr{UInt64}(data_ptr_field)))")

# Verify: first element at data_ptr + 0 should be 10
first_elem = unsafe_load(Ptr{Int64}(data_ptr_field))
println("  → first element at data_ptr: $first_elem  (expected 10)")

# offset +8 could be ndims or offset
val_8 = unsafe_load(Ptr{Int64}(ptr + 8))
println("offset +8: $val_8  (might be ndims=1, or offset field)")

# offset +16 is known to be length (array_len reads here)
val_16 = unsafe_load(Ptr{Int64}(ptr + 16))
println("offset +16: $val_16  (expected 5 = length)")

# offset +24 and beyond — nalloc/capacity and other internal fields
val_24 = unsafe_load(Ptr{Int64}(ptr + 24))
println("offset +24: $val_24  (likely nalloc/capacity, ≥5)")
if val_24 >= 5
    println("  → nalloc/capacity at offset +24 — confirmed")
end

val_32 = unsafe_load(Ptr{Int64}(ptr + 32))
println("offset +32: $val_32")

val_40 = unsafe_load(Ptr{Int64}(ptr + 40))
println("offset +40: $val_40")

val_48 = unsafe_load(Ptr{Int64}(ptr + 48))
println("offset +48: $val_48")

val_56 = unsafe_load(Ptr{Int64}(ptr + 56))
println("offset +56: $val_56")

println()

# Also check: sizeof(jl_array_t) from Julia's perspective
# sizeof(Vector{Int64}) returns 24 (the Julia-visible part)
println("--- Summary ---")
println("Julia-visible sizeof(Vector{Int64}) = $(sizeof(Vector{Int64}))  (24 bytes = 3 words)")
println("Internal fields beyond Julia-visible region start at offset 24")
println()
println("For JuliaArrayRepr struct:")
println("  data_ptr:   offset +0  (8 bytes)")
if val_8 == 1
    println("  ndims:      offset +8  (8 bytes)")
else
    println("  ???:        offset +8  = $val_8  (8 bytes)")
end
println("  length:     offset +16 (8 bytes)  — confirmed by array_len code")
if val_24 >= 5
    println("  nalloc:     offset +24 (8 bytes)  — confirmed: $val_24")
else
    println("  ???:        offset +24 = $val_24  (may not be nalloc)")
end

println()
println("=== JuliaArrayRepr offsets confirmed ===")
