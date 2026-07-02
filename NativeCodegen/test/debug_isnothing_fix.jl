using JuliaSyntax: JuliaSyntax
using NativeCodegen

# Quick test of the NOTHING_TAG fix for isnothing/is_leaf
println("=== Test: isnothing / is_leaf with NOTHING_TAG fix ===\n")

# Parse a seed tree
tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
gntype = typeof(tree)

# Get a leaf node for testing
leaf = JuliaSyntax.children(tree)[3]  # typically a leaf

println("Host JuliaSyntax results:")
println("  is_leaf(tree): ", JuliaSyntax.is_leaf(tree))
println("  is_leaf(leaf): ", JuliaSyntax.is_leaf(leaf))

# Test is_leaf directly
println("\n=== is_leaf compilation ===")
f_isleaf(n::gntype) = JuliaSyntax.is_leaf(n)
try
    result_tree = compile_and_call(f_isleaf, Bool, Tuple{gntype}, tree; name="isleaf_fix")
    result_leaf = compile_and_call(f_isleaf, Bool, Tuple{gntype}, leaf; name="isleaf_fix2")
    println("  tree: compiled=$(result_tree), expected=false, match=$(result_tree==false)")
    println("  leaf: compiled=$(result_leaf), expected=true, match=$(result_leaf==true)")
catch e
    println("  COMPILE ERROR: $(typeof(e)): $e")
end

# Test isnothing directly
println("\n=== isnothing compilation ===")
f_isnothing(x::Union{Nothing, Vector{gntype}}) = x === nothing
try
    result_nothing = compile_and_call(f_isnothing, Bool, Tuple{Union{Nothing, Vector{gntype}}}, nothing; name="isnothing_nothing")
    result_vec = compile_and_call(f_isnothing, Bool, Tuple{Union{Nothing, Vector{gntype}}}, JuliaSyntax.children(tree); name="isnothing_vec")
    println("  nothing arg: compiled=$(result_nothing), expected=true, match=$(result_nothing==true)")
    println("  vec arg: compiled=$(result_vec), expected=false, match=$(result_vec==false)")
catch e
    println("  COMPILE ERROR: $(typeof(e)): $e")
end

# Test children comparison via is_leaf
println("\n=== children() isnothing test ===")
f_check_children(n::gntype) = JuliaSyntax.children(n) === nothing
try
    result_tree2 = compile_and_call(f_check_children, Bool, Tuple{gntype}, tree; name="check_kids_tree")
    result_leaf2 = compile_and_call(f_check_children, Bool, Tuple{gntype}, leaf; name="check_kids_leaf")
    println("  tree (has children): compiled=$(result_tree2), expected=false, match=$(result_tree2==false)")
    println("  leaf (no children): compiled=$(result_leaf2), expected=true, match=$(result_leaf2==true)")
catch e
    println("  COMPILE ERROR: $(typeof(e)): $e")
end
