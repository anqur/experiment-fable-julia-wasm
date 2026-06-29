# Test string parameter operations

using NativeCodegen
using Test

println("=== Testing String Parameter Operations ===")

@testset "String parameter operations" begin
    # Test 1: String length comparison
    function string_length_check(s::String)
        len = sizeof(s)
        return len > 5
    end

    println("\n1. Testing string_length_check:")
    try
        comp = compile_native(string_length_check, Tuple{String})
        nf = native_callable(comp, Bool, String)

        @test nf("hello") == false    # length 5, not > 5
        @test nf("hello world") == true  # length 11, > 5
        @test nf("") == false         # length 0, not > 5

        println("✓ string_length_check works!")

    catch e
        println("Error: $e")
        @test false
    end

    # Test 2: String size return
    function get_string_size(s::String)
        return sizeof(s)
    end

    println("\n2. Testing get_string_size:")
    try
        comp = compile_native(get_string_size, Tuple{String})
        nf = native_callable(comp, Int64, String)

        @test nf("a") == 1
        @test nf("ab") == 2
        @test nf("abc") == 3

        println("✓ get_string_size works!")

    catch e
        println("Error: $e")
        @test false
    end

    # Test 3: Empty string check
    function is_empty_string(s::String)
        return sizeof(s) == 0
    end

    println("\n3. Testing is_empty_string:")
    try
        comp = compile_native(is_empty_string, Tuple{String})
        nf = native_callable(comp, Bool, String)

        @test nf("") == true
        @test nf("a") == false

        println("✓ is_empty_string works!")

    catch e
        println("Error: $e")
        @test false
    end
end

println("\n=== String Parameter Tests Complete ===")