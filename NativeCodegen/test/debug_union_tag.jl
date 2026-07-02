using JuliaSyntax: JuliaSyntax
import Base: fieldoffset

tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
gntype = typeof(tree)
leaf = JuliaSyntax.children(tree)[3]

# Read children field from actual GreenNode (leaf = nothing)
offset = fieldoffset(gntype, :children)
r = Ref(leaf)
p = convert(Ptr{Cvoid}, pointer_from_objref(r))
data_ptr = unsafe_load(convert(Ptr{Ptr{Cvoid}}, p))
leaf_raw = unsafe_load(convert(Ptr{UInt64}, data_ptr + offset))
println("Leaf nothing tag: 0x", string(leaf_raw, base=16))

# Read children field from tree node (has children)
r2 = Ref(tree)
p2 = convert(Ptr{Cvoid}, pointer_from_objref(r2))
data_ptr2 = unsafe_load(convert(Ptr{Ptr{Cvoid}}, p2))
tree_raw = unsafe_load(convert(Ptr{UInt64}, data_ptr2 + offset))
println("Tree children ptr: 0x", string(tree_raw, base=16))
