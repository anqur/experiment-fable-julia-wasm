# Comprehensive test of all new features implemented

using NativeCodegen
using Test

println("=== Comprehensive New Features Test ===")

# Test 1: Multi-Field Bitstype Support
println("\n1. Multi-Field Bitstype Support")
struct BitstwoFields
    a::Int32
    b::UInt8
    c::Int32
end

function test_bitstype_extraction()
    bs = BitstwoFields(1, 2, 3)
    return bs.b  # Extract middle UInt8 field
end

result = compile_and_call(test_bitstype_extraction, UInt8, Tuple{})
println("  BitstwoFields(1, 2, 3).b = $result")
@test result == UInt8(2)
println("  ✅ Multi-field bitstype extraction works!")

# Test 2: Tuple Support
println("\n2. Multi-Element Tuple Support")
function test_tuple_creation()
    x = 10
    y = 20
    z = 30
    return (x, y, z)
end

result = compile_and_call(test_tuple_creation, Tuple{Int64, Int64, Int64}, Tuple{})
println("  Created tuple: $result")
@test result == (10, 20, 30)
println("  ✅ Multi-element tuple creation works!")

# Test 3: Mixed-Type Tuple
println("\n3. Mixed-Type Tuple Support")
function test_mixed_tuple()
    return (42, 3.14, true, 100)
end

result = compile_and_call(test_mixed_tuple, Tuple{Int64, Float64, Bool, Int64}, Tuple{})
println("  Mixed tuple: $result")
@test result == (42, 3.14, true, 100)
println("  ✅ Mixed-type tuple creation works!")

# Test 4: Complex Tuple Operations
println("\n4. Complex Tuple Operations")
function test_tuple_arithmetic()
    a = 5
    b = 7
    tuple_result = (a, b)
    return tuple_result  # Return tuple with computed values
end

result = compile_and_call(test_tuple_arithmetic, Tuple{Int64, Int64}, Tuple{})
println("  Tuple from computation: $result")
@test result == (5, 7)
println("  ✅ Tuple with computed values works!")

println("\n=== All New Features Verified ===")
println("✅ Multi-field bitstype support")
println("✅ Multi-element tuple support")
println("✅ Mixed-type tuple support")
println("✅ Complex tuple operations")
println("\n🎉 All new features working correctly!")