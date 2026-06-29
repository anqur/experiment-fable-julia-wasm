# Test minimal control flow

using NativeCodegen
using Test

println("=== Testing Minimal Control Flow ===")

# First test a function that definitely works
@testset "Baseline test" begin
    function baseline(s::String)
        return sizeof(s)
    end

    comp = compile_native(baseline, Tuple{String})
    nf = native_callable(comp, Int64, String)
    @test nf("hello") == 5
    println("✓ Baseline works")
end

# Now test the simplest possible control flow
@testset "Minimal control flow" begin
    function minimal_control(s::String)
        sz = sizeof(s)
        if sz > 0
            return 1
        else
            return 0
        end
    end

    try
        comp = compile_native(minimal_control, Tuple{String})
        nf = native_callable(comp, Int64, String)
        @test nf("") == 0
        @test nf("hello") == 1
        println("✓ Minimal control flow works!")
    catch e
        println("✗ Error: $e")
        @test false
    end
end

println("\n=== Tests Complete ===")