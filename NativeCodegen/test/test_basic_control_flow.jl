# Test basic control flow without strings

using NativeCodegen
using Test

println("=== Testing Basic Control Flow (no strings) ===")

# Test 1: Simple integer if/else
function test_int_if(a::Int)
    if a > 0
        return 1
    else
        return 0
    end
end

println("Test 1: Integer if/else")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, test_int_if, Tuple{Int})
    println("Generated CLIF:")
    println(clif)

    comp = compile_native(test_int_if, Tuple{Int})
    nf = native_callable(comp, Int64, Int)

    @test nf(5) == 1
    @test nf(-5) == 0
    println("✓ Integer if/else works!")
catch e
    println("✗ Integer if/else failed: $e")
end

# Test 2: Simple arithmetic if/else
function test_arith_if(a::Int)
    if a > 10
        return a + 5
    else
        return a - 5
    end
end

println("\nTest 2: Arithmetic if/else")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, test_arith_if, Tuple{Int})
    println("Generated CLIF:")
    println(clif)

    comp = compile_native(test_arith_if, Tuple{Int})
    nf = native_callable(comp, Int64, Int)

    @test nf(15) == 20
    @test nf(5) == 0
    println("✓ Arithmetic if/else works!")
catch e
    println("✗ Arithmetic if/else failed: $e")
end

println("\n=== Basic Control Flow Tests Complete ===")