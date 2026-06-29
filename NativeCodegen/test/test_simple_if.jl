# Test simple if/else compilation

using NativeCodegen
using Test

println("=== Testing Simple If/Else ===")

function test_simple_if(a::Int)
    if a > 0
        return 1
    else
        return 0
    end
end

try
    interp = NativeCodegen.WasmCodegen.WasmInterp()

    # First check CLIF generation
    clif = NativeCodegen.compile_to_clif(interp, test_simple_if, Tuple{Int})
    println("Generated CLIF:")
    println(clif)

    # Try compilation
    comp = compile_native(test_simple_if, Tuple{Int})
    nf = native_callable(comp, Int64, Int)

    @test nf(5) == 1
    @test nf(-5) == 0
    @test nf(0) == 0

    println("✓ Simple if/else works!")
catch e
    println("✗ Error: $e")
    @test false
end

println("\n=== Test Complete ===")