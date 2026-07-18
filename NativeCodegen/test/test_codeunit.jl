# Test codeunit function for character access

using NativeCodegen
using Test

println("=== Testing codeunit Function ===")

function string_codeunit(s::String, i::Int)
    return codeunit(s, i)
end

println("Testing codeunit(String, Int):")
try
    # First check the CLIF generation
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_codeunit, Tuple{String, Int})
    println("Generated CLIF:")
    println(clif)

    # Now try to compile
    comp = compile_native(string_codeunit, Tuple{String, Int})
    nf = native_callable(comp, UInt8, String, Int)

    @test nf("hello", 1) == 0x68  # 'h'
    @test nf("hello", 2) == 0x65  # 'e'
    @test nf("hello", 5) == 0x6f  # 'o'
    println("✓ codeunit(String, Int) works!")
catch e
    println("✗ Error: $e")
    @test false
end

println("\n=== Test Complete ===")
