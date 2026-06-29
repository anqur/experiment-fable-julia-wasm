# Simple string equality test

using NativeCodegen
using Test

println("=== Simple String Equality Test ===")

# Try a different approach - use === instead of ==
function string_eq_simple(s1::String, s2::String)
    return s1 === s2
end

println("Testing s1 === s2:")
try
    comp = compile_native(string_eq_simple, Tuple{String, String})
    nf = native_callable(comp, Bool, String, String)

    @test nf("hello", "hello") == true
    @test nf("hello", "world") == false
    println("✓ String === works!")
catch e
    println("✗ Error: $e")
    @test false
end

println("\n=== Test Complete ===")