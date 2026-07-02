using JuliaSyntax: JuliaSyntax

# Compute NOTHING_TAG properly by reading a union field at runtime.
# Create a mutable wrapper struct (on the heap) so pointer_from_objref works directly.

tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
gntype = typeof(tree)
leaf = JuliaSyntax.children(tree)[3]

# Method 1: Read from actual GreenNode (most reliable)
offset = Base.fieldoffset(gntype, :children)
r = Ref(leaf)
p = convert(Ptr{Cvoid}, pointer_from_objref(r))
# For a non-bitstype immutable struct, Ref stores a POINTER
data_ptr = unsafe_load(convert(Ptr{Ptr{Cvoid}}, p))
leaf_raw = unsafe_load(convert(Ptr{UInt64}, data_ptr + offset))
println("Method 1 (GreenNode leaf): 0x", string(leaf_raw, base=16))
println("  low bits: ", leaf_raw & 0xF)

# Method 2: Use a simple immutable struct with a union field
struct Probe
    x::Union{Nothing, Vector{Int}}
end
probe = Probe(nothing)
r2 = Ref(probe)
p2 = convert(Ptr{Cvoid}, pointer_from_objref(r2))
# For a single-field immutable struct (like Probe), the data is inline in RefValue
probe_raw = unsafe_load(convert(Ptr{UInt64}, p2 + Base.fieldoffset(Probe, :x)))
println("Method 2 (Probe struct): 0x", string(probe_raw, base=16))
println("  low bits: ", probe_raw & 0xF)

# Verify they match
println("Match: ", leaf_raw == probe_raw)
