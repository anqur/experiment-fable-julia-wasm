# Test invoke support for length(String)

using NativeCodegen
using Test

println("=== Testing Invoke Support ===")

@testset "Invoke support for length(String)" begin
    function string_length_test(s::String)
        return length(s)
    end

    println("\n1. Testing length(String) compilation:")
    try
        comp = compile_native(string_length_test, Tuple{String})
        nf = native_callable(comp, Int64, String)

        @test nf("hello") == 5
        @test nf("world") == 5
        @test nf("hi") == 2
        @test nf("") == 0

        println("✓ length(String) working!")

    catch e
        println("Error: $e")
        @test false
    end
end

println("\n=== Invoke Support Test Complete ===")