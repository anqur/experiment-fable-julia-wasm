# Test multi-element tuple support

using NativeCodegen
using Test

println("=== Testing Multi-Element Tuples ===")

function test_tuple2()
    return (1, 2)
end

function test_tuple3()
    return (1, 2, 3)
end

function test_tuple_mixed()
    return (1, 2.5, 3)
end

println("1. Testing 2-element tuple...")
try
    result = compile_and_call(test_tuple2, Tuple{Int64, Int64}, Tuple{})
    println("   Result: $result")
    @test result == (1, 2)
    println("   ✅ 2-element tuple works!")
catch e
    println("   ❌ Error: $e")
end

println("\n2. Testing 3-element tuple...")
try
    result = compile_and_call(test_tuple3, Tuple{Int64, Int64, Int64}, Tuple{})
    println("   Result: $result")
    @test result == (1, 2, 3)
    println("   ✅ 3-element tuple works!")
catch e
    println("   ❌ Error: $e")
end

println("\n3. Testing mixed-type tuple...")
try
    result = compile_and_call(test_tuple_mixed, Tuple{Int64, Float64, Int64}, Tuple{})
    println("   Result: $result")
    @test result == (1, 2.5, 3)
    println("   ✅ Mixed-type tuple works!")
catch e
    println("   ❌ Error: $e")
end

println("\n=== Multi-Element Tuple Tests Complete ===")