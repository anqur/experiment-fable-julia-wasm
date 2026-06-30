# Test multi-field bitstype support

using NativeCodegen
using Test

println("=== Testing Multi-Field Bitstypes ===")

# Test 1: Simple multi-field bitstype
struct BitstwoFields
    a::UInt8
    b::UInt8
    c::UInt16
end

function test_bitstype_extract(b::BitstwoFields)
    return b.b  # Should extract 2nd UInt8 field
end

println("1. Testing multi-field bitstype extraction...")
try
    comp = compile_native(test_bitstype_extract, Tuple{BitstwoFields})
    f = native_callable_from_so(comp, UInt8, BitstwoFields)
    result = f(BitstwoFields(UInt8(1), UInt8(2), UInt16(3)))
    println("   Result: $result")
    @test result == UInt8(2)
    println("   ✅ Multi-field bitstype extraction works!")
    rm(comp.so_path)
catch e
    println("   ❌ Error: $e")
end

# Test 2: Nested bitstype in struct
mutable struct Container
    value::BitstwoFields
end

function test_nested_bitstype(c::Container)
    return c.value.a  # Should access nested bitstype field
end

println("\n2. Testing nested bitstype access...")
try
    comp = compile_native(test_nested_bitstype, Tuple{Container})
    f = native_callable_from_so(comp, UInt8, Container)
    container = Container(BitstwoFields(UInt8(10), UInt8(20), UInt16(30)))
    result = f(container)
    println("   Result: $result")
    @test result == UInt8(10)
    println("   ✅ Nested bitstype access works!")
    rm(comp.so_path)
catch e
    println("   ❌ Error: $e")
end

println("\n=== Multi-Field Bitstype Tests Complete ===")