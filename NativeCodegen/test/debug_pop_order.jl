using NativeCodegen
using NativeCodegen: compile_and_call

println("=== Execution order investigation ===")

# Test: does resize! execute before the element read?
function test_order(a::Vector{Int64})
    n = length(a)
    println("  n = $n")
    @inbounds v = a[n]
    println("  v = $v")
    resize!(a, n-1)
    println("  after resize, length = $(length(a))")
    v
end

print("  test_order [10,20,30] ... ")
try
    a = Int64[10,20,30]
    r = compile_and_call(test_order, Int64, Tuple{Vector{Int64}}, a)
    println("returned: $r")
catch e
    println("❌ ", e)
end

# Check if it's a phi node issue - different path for n
function test_phi(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    v  # return directly, no resize
end

print("  test_phi [10,20,30] ... ")
try
    a = Int64[10,20,30]
    r = compile_and_call(test_phi, Int64, Tuple{Vector{Int64}}, a)
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end
