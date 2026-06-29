# Test eDSL builder approach

using NativeCodegen
using Test

println("=== Testing eDSL Builder Approach ===")

# Test 1: Simple integer addition
function test_add(a::Int, b::Int)
    return a + b
end

println("Test 1: Integer addition")
try
    comp = compile_native(test_add, Tuple{Int, Int})
    println("✅ Compilation succeeded!")
    println("Generated .so: $(comp.so_path)")
    println("Function name: $(comp.func_name)")

    # Test with native_callable_from_so
    nf = native_callable_from_so(comp, Int64, Int, Int)
    result = nf(5, 3)
    println("Result of nf(5, 3): $result")

    @test result == 8
    println("✅ Integer addition test passed!")

    # Clean up
    rm(comp.so_path)
catch e
    println("❌ Test failed: $e")
    @test false
end

println("\n=== Test Complete ===")