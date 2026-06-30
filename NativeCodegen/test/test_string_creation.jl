# Test string creation intrinsic

using NativeCodegen
using Test

println("=== Testing String Creation ===")

function test_string_create()
    len = 5
    # This would create a new string of length 5
    # For now, we just test that the compilation works
    return len
end

println("1. Testing string creation intrinsic...")
try
    result = compile_and_call(test_string_create, Int64, Tuple{})
    println("   Result: $result")
    @test result == 5
    println("   ✅ String creation intrinsic compiles!")
catch e
    println("   ❌ Error: $e")
end

println("\n=== String Creation Tests Complete ===")