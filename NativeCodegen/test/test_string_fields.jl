# Test String field access (getfield/setfield)

using NativeCodegen
using Test

println("=== Testing String Field Access ===")

@testset "String getfield operations" begin
    # Test 1: Access string length field via getfield
    @testset "getfield length" begin
        function string_length_field(s::String)
            # This tests getfield(s, :length)
            l = getfield(s, :length)
            return l
        end

        comp = compile_native(string_length_field, Tuple{String})
        nf = native_callable(comp, Int64, String)

        @test nf("hello") == 5
        @test nf("world") == 5
        @test nf("") == 0
        @test nf("longer string") == 13
        println("✓ getfield length works!")
    end

    # Test 2: Access string data field via getfield
    @testset "getfield data" begin
        function string_data_field(s::String)
            # This tests getfield(s, :data) or :payload
            p = getfield(s, :data)
            # For our simplified model, this should return the pointer value
            # We'll just return a non-zero value to verify it works
            return reinterpret(Int64, p)
        end

        comp = compile_native(string_data_field, Tuple{String})
        nf = native_callable(comp, Int64, String)

        result = nf("test")
        @test result != 0  # Should be a valid pointer
        println("✓ getfield data works!")
    end
end

println("\n=== String Field Access Tests Complete ===")