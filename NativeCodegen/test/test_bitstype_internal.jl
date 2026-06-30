# Test multi-field bitstype without direct bitstype arguments

using NativeCodegen
using Test

println("=== Testing Multi-Field Bitstypes (Internal) ===")

# Test bitstype field extraction from within function
struct BitstwoFields
    a::UInt8
    b::UInt8
    c::UInt16
end

function test_internal_bitstype()
    b = BitstwoFields(UInt8(1), UInt8(2), UInt16(3))
    return b.b  # Extract second field
end

println("1. Testing bitstype field extraction (no bitstype args)...")
try
    result = compile_and_call(test_internal_bitstype, UInt8, Tuple{})
    println("   Result: $result")
    @test result == UInt8(2)
    println("   ✅ Multi-field bitstype extraction works!")
catch e
    println("   ❌ Error: $e")
end

# Test with larger bitstypes
struct LargeBitstype
    small1::UInt8
    small2::UInt8
    large::UInt64
    small3::UInt8
end

function test_large_bitstype()
    l = LargeBitstype(UInt8(1), UInt8(2), UInt64(0x1234567890), UInt8(3))
    return l.small3  # Extract field after large field
end

println("\n2. Testing bitstype with mixed field sizes...")
try
    result = compile_and_call(test_large_bitstype, UInt8, Tuple{})
    println("   Result: $result")
    @test result == UInt8(3)
    println("   ✅ Mixed-size bitstype extraction works!")
catch e
    println("   ❌ Error: $e")
end

println("\n=== Multi-Field Bitstype Tests Complete ===")