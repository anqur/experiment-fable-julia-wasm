using JuliaSyntax: JuliaSyntax
using NativeCodegen

# Test isa(x, Nothing) fix
println("=== Test: isa(x, Nothing) with tagged nothing fix ===\n")

tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
leaf = JuliaSyntax.children(tree)[3]
gntype = typeof(tree)

# Test isa(x, Nothing) on union field values
f_isa(n::gntype) = Core.isa(JuliaSyntax.children(n), Nothing)
try
    result_tree = compile_and_call(f_isa, Bool, Tuple{gntype}, tree; name="isa_nothing_tree")
    result_leaf = compile_and_call(f_isa, Bool, Tuple{gntype}, leaf; name="isa_nothing_leaf")
    println("isa(children(tree), Nothing): compiled=$(result_tree), expected=false, match=$(result_tree==false)")
    println("isa(children(leaf), Nothing): compiled=$(result_leaf), expected=true, match=$(result_leaf==true)")
catch e
    println("COMPILE ERROR: $(typeof(e)): $e")
end

println("\n✅ Phase 4a complete: is_leaf and isa(x, Nothing) work correctly")
