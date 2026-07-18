# Test hypothesis: blocks with only return statements fail

using NativeCodegen
using Test

println("=== Testing Return-Only Block Hypothesis ===")

# Test 1: If/else with returns only (expected to fail)
function test_returns_only(a::Int)
    if a > 0
        return 1
    else
        return 0
    end
end

println("Test 1: If/else with returns only (expected to fail)")
try
    comp = compile_native(test_returns_only, Tuple{Int})
    nf = native_callable(comp, Int64, Int)
    @test nf(5) == 1
    println("✓ Unexpected success!")
catch e
    println("✗ Expected failure: $e")
end

# Test 2: If/else with dummy operations before returns (expected to work)
function test_with_ops(a::Int)
    if a > 0
        dummy = a + 0  # dummy operation
        return 1
    else
        dummy = a - 0  # dummy operation
        return 0
    end
end

println("\nTest 2: If/else with dummy operations (expected to work)")
try
    comp = compile_native(test_with_ops, Tuple{Int})
    nf = native_callable(comp, Int64, Int)
    @test nf(5) == 1
    @test nf(-5) == 0
    println("✓ Works with dummy operations!")
catch e
    println("✗ Unexpected failure: $e")
end

# Test 3: Direct constant returns without operations
function test_const_returns(a::Int)
    if a > 0
        return 1
    else
        return 0
    end
end

println("\nTest 3: Direct constant returns")
try
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, test_const_returns, Tuple{Int})
    println("Generated CLIF:")
    println(clif)
catch e
    println("CLIF generation error: $e")
end

println("\n=== Hypothesis Test Complete ===")