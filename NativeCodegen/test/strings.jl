# String operations tests for NativeCodegen

using NativeCodegen
using Test

@testset "String sizeof operation" begin
    function string_len_test(s::String)
        return sizeof(s)
    end

    comp = compile_native(string_len_test, Tuple{String})
    nf = native_callable(comp, Int64, String)

    @testset "basic strings" begin
        @test nf("hello") == 5
        @test nf("hello world") == 11
        @test nf("hi") == 2
        @test nf("") == 0
    end

    @testset "unicode strings" begin
        @test nf("hello world") == 11
        @test nf("test") == 4
    end
end

@testset "String length operation" begin
    function string_length_test(s::String)
        return length(s)
    end

    comp = compile_native(string_length_test, Tuple{String})
    nf = native_callable(comp, Int64, String)

    @testset "basic strings" begin
        @test nf("hello") == 5
        @test nf("world") == 5
        @test nf("") == 0
    end
end

println("\n=== String operations tests completed ===")