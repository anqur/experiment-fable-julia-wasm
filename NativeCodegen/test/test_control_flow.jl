# Test control flow compilation

using NativeCodegen
using Test

println("=== Testing Control Flow Compilation ===")

@testset "Control flow compilation" begin
    # Test 1: Simple control flow
    @testset "Simple control flow" begin
        function simple_control(s::String)
            if sizeof(s) > 3
                return 1
            else
                return 0
            end
        end

        try
            comp = compile_native(simple_control, Tuple{String})
            nf = native_callable(comp, Int64, String)

            @test nf("ab") == 0
            @test nf("hello") == 1
            println("✓ Simple control flow works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end

    # Test 2: More complex control flow
    @testset "Complex control flow" begin
        function complex_control(s::String)
            sz = sizeof(s)
            if sz > 5
                return 2
            elseif sz > 2
                return 1
            else
                return 0
            end
        end

        try
            comp = compile_native(complex_control, Tuple{String})
            nf = native_callable(comp, Int64, String)

            @test nf("a") == 0
            @test nf("abc") == 1
            @test nf("hello world") == 2
            println("✓ Complex control flow works!")
        catch e
            println("✗ Error: $e")
            @test false
        end
    end
end

println("\n=== Control Flow Compilation Tests Complete ===")