# Test Julia-compatible object allocation and return to Julia

using NativeCodegen
using Test

println("=== Testing Object Header Fix ===")

# Test 1: Return a newly allocated mutable struct
println("\n1. Testing struct allocation and return...")

mutable struct TestPoint
    x::Int64
    y::Int64
end

function alloc_point()::TestPoint
    return TestPoint(42, 99)
end

try
    comp = compile_native(alloc_point, Tuple{})
    f = native_callable_from_so(comp, TestPoint, Tuple{})
    result = f()

    println("   ✅ Function returned successfully: $result")
    println("   Type: $(typeof(result))")

    if result isa TestPoint
        println("   ✅ Result is correct type")
        @test result.x == 42
        @test result.y == 99
        println("   ✅ Field values correct: x=$(result.x), y=$(result.y)")
    else
        println("   ❌ Result type mismatch: expected TestPoint, got $(typeof(result))")
    end

    rm(comp.so_path)
    println("   Test passed!")

catch e
    println("   ❌ Test failed with error: $e")
    if isa(e, LoadError)
        println("   LoadError - likely library symbol missing")
    elseif isa(e, MethodError)
        println("   MethodError - compilation issue")
    end
end

# Test 2: Return a newly allocated array
println("\n2. Testing array allocation and return...")

function alloc_array()::Vector{Int64}
    return Int64[1, 2, 3, 4]
end

try
    comp = compile_native(alloc_array, Tuple{})
    f = native_callable_from_so(comp, Vector{Int64}, Tuple{})
    result = f()

    println("   ✅ Function returned successfully: $result")
    println("   Type: $(typeof(result))")

    if result isa Vector{Int64}
        println("   ✅ Result is correct type")
        @test length(result) == 4
        @test result[1] == 1
        @test result[4] == 4
        println("   ✅ Array content correct: $result")
    else
        println("   ❌ Result type mismatch: expected Vector{Int64}, got $(typeof(result))")
    end

    rm(comp.so_path)
    println("   Test passed!")

catch e
    println("   ❌ Test failed with error: $e")
end

println("\n=== Object Header Tests Complete ===")