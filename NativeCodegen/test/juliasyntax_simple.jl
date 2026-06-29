# Simple JuliaSyntax compilation test

using NativeCodegen
using Test
using JuliaSyntax

println("=== JuliaSyntax Simple Compilation Test ===")

@testset "JuliaSyntax basic compilation" begin
    # Test 1: Simple tokenization wrapper
    function simple_tokenize(input::String)
        try
            tokens = JuliaSyntax.tokenize(input)
            return length(tokens)
        catch e
            return -1
        end
    end

    println("\n1. Testing tokenize function compilation:")
    try
        comp = compile_native(simple_tokenize, Tuple{String})
        nf = native_callable(comp, Int64, String)
        println("Compilation succeeded!")

        # Test with a simple expression
        result = nf("x + y")
        println("Token count for 'x + y': $result")
        @test result > 0  # Should tokenize successfully

    catch e
        println("Compilation failed: $e")
        @test false  # Mark test as failed
    end

    # Test 2: Even simpler - just return the string
    function identity_string(s::String)
        return s
    end

    println("\n2. Testing identity_string compilation:")
    try
        comp = compile_native(identity_string, Tuple{String})
        nf = native_callable(comp, Ptr{Cvoid}, String)
        println("Compilation succeeded!")

        # This should work since we're just returning the pointer
        test_str = "hello"
        result = nf(test_str)
        println("Identity function returned: $result")
        @test result != C_NULL  # Should return a non-null pointer

    catch e
        println("Compilation failed: $e")
        @test false  # Mark test as failed
    end

    # Test 3: String comparison
    function string_eq(s1::String, s2::String)
        return s1 == s2
    end

    println("\n3. Testing string comparison compilation:")
    try
        comp = compile_native(string_eq, Tuple{String, String})
        nf = native_callable(comp, Bool, String, String)
        println("Compilation succeeded!")

        result = nf("hello", "hello")
        println("'hello' == 'hello': $result")
        @test result == true

        result2 = nf("hello", "world")
        println("'hello' == 'world': $result2")
        @test result2 == false

    catch e
        println("Compilation failed: $e")
        @test false  # Mark test as failed
    end
end

println("\n=== JuliaSyntax Simple Test Complete ===")