# Test very basic string operations

using NativeCodegen
using Test

println("=== Testing Basic String Operations ===")

@testset "Basic string operations" begin
    # Test 1: String parameter and return
    function string_identity(s::String)
        return s
    end

    println("\n1. Testing string_identity (should return pointer):")
    try
        comp = compile_native(string_identity, Tuple{String})
        println("Compilation succeeded!")

        # The issue is with creating the callable for String return type
        # Let me check what return type we're getting

    catch e
        println("Compilation failed: $e")
    end

    # Test 2: String length via sizeof (we know this works)
    function string_sizeof(s::String)
        return sizeof(s)
    end

    println("\n2. Testing string_sizeof (known to work):")
    try
        comp = compile_native(string_sizeof, Tuple{String})
        nf = native_callable(comp, Int64, String)

        result = nf("test")
        println("sizeof('test'): $result")
        @test result == 4

    catch e
        println("Error: $e")
    end

    # Test 3: Simple string creation
    function make_string()
        return "hello"
    end

    println("\n3. Testing make_string (constant string):")
    try
        comp = compile_native(make_string, Tuple{})
        println("Compilation succeeded!")

        # This should return something
        nf = native_callable(comp, Ptr{Cvoid})
        result = nf()
        println("make_string() returned: $result")

    catch e
        println("Error: $e")
    end
end

println("\n=== Basic String Tests Complete ===")