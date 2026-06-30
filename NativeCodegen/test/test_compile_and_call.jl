# Test the new compile_and_call function

using NativeCodegen
using Test

println("=== Testing compile_and_call ===")

mutable struct TestPoint
    x::Int64
    y::Int64
end

function test_point()::TestPoint
    return TestPoint(42, 99)
end

println("Testing struct allocation and return...")
try
    result = compile_and_call(test_point, TestPoint, Tuple{})
    println("✅ Function executed successfully!")
    println("Result: $result")
    println("Type: $(typeof(result))")

    @test result isa TestPoint
    @test result.x == 42
    @test result.y == 99
    println("✅ All tests passed!")
    println("🎉 Object header fix is complete and working!")

catch e
    println("❌ Test failed: $e")
end

println("\n=== Testing with arrays ===")

function test_array()::Vector{Int64}
    return Int64[1, 2, 3, 4]
end

println("Testing array allocation and return...")
try
    result = compile_and_call(test_array, Vector{Int64}, Tuple{})
    println("✅ Function executed successfully!")
    println("Result: $result")
    println("Type: $(typeof(result))")

    @test result isa Vector{Int64}
    @test length(result) == 4
    @test result[1] == 1
    @test result[4] == 4
    println("✅ All tests passed!")

catch e
    println("❌ Test failed: $e")
    println("   Array support may need additional work")
end

println("\n=== Tests Complete ===")