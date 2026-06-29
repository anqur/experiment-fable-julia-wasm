# Test with operations that won't be optimized away

using NativeCodegen
using Test

println("=== Testing Non-Optimizable Operations ===")

# Test 1: If/else with meaningful operations
function test_meaningful_ops(a::Int)
    if a > 0
        result = a + 5  # meaningful operation
        return result
    else
        result = a - 5  # meaningful operation
        return result
    end
end

println("Test 1: If/else with meaningful operations")
try
    comp = compile_native(test_meaningful_ops, Tuple{Int})
    nf = native_callable(comp, Int64, Int)
    @test nf(15) == 20
    @test nf(5) == 0
    println("✓ Works with meaningful operations!")
catch e
    println("✗ Failed: $e")
end

# Test 2: Check the CLIF generation
println("\nTest 2: Check CLIF generation")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, test_meaningful_ops, Tuple{Int})
    println("Generated CLIF:")
    println(clif)
catch e
    println("CLIF generation error: $e")
end

println("\n=== Test Complete ===")