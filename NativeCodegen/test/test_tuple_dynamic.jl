# Test dynamic tuple creation (not constants)

using NativeCodegen
using Test

println("=== Testing Dynamic Tuple Creation ===")

function test_tuple_from_args(a::Int64, b::Int64)
    return (a, b)
end

function test_tuple_from_vars()
    x = 1
    y = 2
    return (x, y)
end

println("1. Testing tuple from function args...")
try
    result = compile_and_call(test_tuple_from_args, Tuple{Int64, Int64}, Tuple{Int64, Int64}, 5, 7)
    println("   Result: $result")
    @test result == (5, 7)
    println("   ✅ Tuple from args works!")
catch e
    println("   ❌ Error: $e")
end

println("\n2. Testing tuple from variables...")
try
    result = compile_and_call(test_tuple_from_vars, Tuple{Int64, Int64}, Tuple{})
    println("   Result: $result")
    @test result == (1, 2)
    println("   ✅ Tuple from vars works!")
catch e
    println("   ❌ Error: $e")
end

println("\n=== Dynamic Tuple Tests Complete ===")