using NativeCodegen
using NativeCodegen: compile_and_call

println("=== Adding resize! ===")

# Just read last element and resize (no unset loop)
function pop_resize_only(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    resize!(a, n-1)
    v
end

print("  pop_resize_only [10,20,30] ... ")
try
    a = Int64[10,20,30]
    r = compile_and_call(pop_resize_only, Int64, Tuple{Vector{Int64}}, a)
    println(r == 30 ? "✅ $r (a after: $a)" : "❌ expected 30, got $r (a after: $a)")
catch e
    println("❌ ", e)
end

# Full pop! for comparison
popone(a::Vector{Int64}) = pop!(a)
print("  pop! [10,20,30] ... ")
try
    a = Int64[10,20,30]
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, a)
    println(r == 30 ? "✅ $r (a after: $a)" : "❌ expected 30, got $r (a after: $a)")
catch e
    println("❌ ", e)
end
