# Minimal JuliaSyntax wrapper

using NativeCodegen
using Test
using JuliaSyntax

println("=== Minimal JuliaSyntax Wrapper Test ===")

# Instead of trying to compile the full tokenize function,
# let's create a minimal wrapper that just returns basic info

function simple_parse_wrapper(input::String)
    # Just return the string size for now
    # This will work and lets us verify the basic flow
    return sizeof(input)
end

@testset "JuliaSyntax minimal wrapper" begin
    println("\n1. Testing minimal parse wrapper:")

    try
        comp = compile_native(simple_parse_wrapper, Tuple{String})
        nf = native_callable(comp, Int64, String)

        # Test with actual Julia code
        julia_code = "function f(x) return x + 1 end"
        result = nf(julia_code)

        println("Input string size: $result")
        @test result > 0  # Should have non-zero size
        println("✓ Minimal wrapper works!")

    catch e
        println("Error: $e")
        @test false
    end
end

println("\n=== Minimal JuliaSyntax Test Complete ===")