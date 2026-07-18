# Test isempty function specifically

using NativeCodegen
using Test

println("=== Testing isempty Function ===")

function string_isempty(s::String)
    return isempty(s)
end

println("Testing isempty(String):")
try
    # First check the CLIF generation
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_isempty, Tuple{String})
    println("Generated CLIF:")
    println(clif)

    # Now try to compile
    comp = compile_native(string_isempty, Tuple{String})
    nf = native_callable(comp, Bool, String)

    @test nf("") == true
    @test nf("hello") == false
    println("✓ isempty(String) works!")
catch e
    println("✗ Error: $e")
    @test false
end

println("\n=== Test Complete ===")