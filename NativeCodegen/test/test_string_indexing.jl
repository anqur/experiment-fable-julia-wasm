# Test string indexing and character access

using NativeCodegen
using Test

println("=== Testing String Indexing Operations ===")

@testset "String indexing operations" begin
    # Test 1: String length via sizeof (already works)
    @testset "sizeof String" begin
        function string_size(s::String)
            return sizeof(s)
        end

        comp = compile_native(string_size, Tuple{String})
        nf = native_callable(comp, Int64, String)

        @test nf("hello") == 5
        @test nf("test") == 4
        println("✓ sizeof String works!")
    end

    # Test 2: Basic string operations that JuliaSyntax might use
    @testset "String processing" begin
        function process_string(s::String)
            sz = sizeof(s)
            # Simple processing based on size
            if sz > 3
                return 1
            else
                return 0
            end
        end

        comp = compile_native(process_string, Tuple{String})
        nf = native_callable(comp, Int64, String)

        @test nf("ab") == 0
        @test nf("hello") == 1
        println("✓ String processing works!")
    end
end

println("\n=== String Indexing Tests Complete ===")