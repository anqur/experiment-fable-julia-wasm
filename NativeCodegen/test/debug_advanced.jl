# Advanced string debugging

using NativeCodegen

println("=== Advanced String Debugging ===")

# Test: Print pointer value and memory contents
function string_debug_test(s::String)
    # Just return the string pointer value for debugging
    return pointer_from_objref(s)
end

println("\n1. Testing pointer extraction:")
test_str = "hello"
str_ptr = pointer_from_objref(test_str)
println("String pointer: ", str_ptr)
println("String value: ", test_str)
println("String length: ", sizeof(test_str))

# Test: Try to manually read memory at pointer location
println("\n2. Testing manual memory read:")
unsafe_ptr = Ptr{UInt8}(str_ptr)
println("Reading bytes at offset -4:")
for i in -4:0
    val = unsafe_load(unsafe_ptr + i, 1)
    println("  Offset $i: $val")
end

# Test: Check if there's a GC header
println("\n3. Testing GC header structure:")
println("Expected GC header size: 12 bytes")
println("Expected layout: [type_tag(4), flags(4), length(4), data(...)]")

# Test: Use the native codegen
println("\n4. Testing native compilation:")
function string_sizeof_test(s::String)
    return sizeof(s)
end

try
    comp = compile_native(string_sizeof_test, Tuple{String})
    nf = native_callable(comp, Int64, String)
    result = nf(test_str)
    println("Native result: $result")
    println("Expected: $(sizeof(test_str))")

    # Try with a simpler string
    simple_str = "x"
    result_simple = nf(simple_str)
    println("Single char '$simple_str': $result (expected: 1)")

catch e
    println("Error: $e")
end

println("\n=== Debug Complete ===")