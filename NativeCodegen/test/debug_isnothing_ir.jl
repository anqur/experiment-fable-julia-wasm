using JuliaSyntax: JuliaSyntax
using NativeCodegen

# Debug: check the IR for is_leaf
tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
leaf = JuliaSyntax.children(tree)[1]
println("leaf is_leaf (host): ", JuliaSyntax.is_leaf(leaf))
println("leaf children is nothing: ", JuliaSyntax.children(leaf) === nothing)

# Check code_instances
f(n) = JuliaSyntax.is_leaf(n)
cis = Base.code_instances(f, (typeof(leaf),))
println("\nNumber of CodeInstances: ", length(cis))
ci = first(cis)

# Get IR
ir = ci.inferred
for (i, stmt) in enumerate(ir.stmts)
    inst = stmt[:inst]
    if inst isa Expr
        println("%$i = $(inst.head) $(length(inst.args) > 0 ? inst.args[1] : ()) :: $(stmt[:type])")
    else
        println("%$i = $inst")
    end
end

# Also check how the compilation works in practice
println("\n=== Compilation test ===")
gntype = typeof(tree)
f2(n::gntype) = JuliaSyntax.is_leaf(n)
try
    comp = compile_native(f2, Tuple{gntype}; name="isleaf_debug2")
    nf = native_callable_from_so(comp, Bool, gntype)
    println("tree (non-leaf): compiled=$(nf(tree)), expected=false, match=$(nf(tree)==false)")
    println("leaf: compiled=$(nf(leaf)), expected=true, match=$(nf(leaf)==true)")
    rm(comp.so_path)
catch e
    println("COMPILE ERROR: $(typeof(e)): $e")
end
