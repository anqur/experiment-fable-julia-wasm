# Test basic invoke operations that JuliaSyntax might use

using NativeCodegen
using Test

println("=== Testing Basic Invoke Operations ===")

@testset "Character operation invokes" begin
    # Test 1: isempty function
    @testset "isempty on String" begin
        function string_isempty(s::String)
            return isempty(s)
        end

        try
            comp = compile_native(string_isempty, Tuple{String})
            nf = native_callable(comp, Bool, String)

            @test nf("") == true
            @test nf("hello") == false
            println("✓ isempty(String) works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end

    # Test 2: first function
    @testset "first on String" begin
        function string_first(s::String)
            return first(s)
        end

        try
            comp = compile_native(string_first, Tuple{String})
            nf = native_callable(comp, UInt8, String)

            result = nf("hello")
            @test result == UInt8('h')
            println("✓ first(String) works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end

    # Test 3: last function
    @testset "last on String" begin
        function string_last(s::String)
            return last(s)
        end

        try
            comp = compile_native(string_last, Tuple{String})
            nf = native_callable(comp, UInt8, String)

            result = nf("hello")
            @test result == UInt8('o')
            println("✓ last(String) works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end
end

println("\n=== Basic Invoke Tests Complete ===")