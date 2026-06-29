# Test string comparison operations

using NativeCodegen
using Test

println("=== Testing String Comparison Operations ===")

@testset "String equality" begin
    @testset "String == operator" begin
        function string_eq(s1::String, s2::String)
            return s1 == s2
        end

        try
            comp = compile_native(string_eq, Tuple{String, String})
            nf = native_callable(comp, Bool, String, String)

            @test nf("hello", "hello") == true
            @test nf("hello", "world") == false
            @test nf("", "") == true
            println("✓ String == works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end
end

println("\n=== String Comparison Tests Complete ===")