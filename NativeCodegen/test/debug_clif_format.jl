# Debug CLIF format issues

using NativeCodegen
using Test

println("=== Debugging CLIF Format ===")

@testset "Compare working vs broken CLIF" begin
    # Test 1: Simple function that works
    println("\n1. Working example (simple sizeof):")
    function simple_size(s::String)
        return sizeof(s)
    end

    try
        interp = NativeCodegen.WasmCodegen.WasmInterp()
        clif = NativeCodegen.compile_to_clif(interp, simple_size, Tuple{String})
        println(clif)
        println("✓ Simple sizeof CLIF generated successfully")
    catch e
        println("✗ Error: $e")
    end

    # Test 2: Function with control flow that breaks
    println("\n2. Broken example (control flow):")
    function process_string(s::String)
        sz = sizeof(s)
        if sz > 3
            return 1
        else
            return 0
        end
    end

    try
        interp = NativeCodegen.WasmCodegen.WasmInterp()
        clif = NativeCodegen.compile_to_clif(interp, process_string, Tuple{String})
        println(clif)
        println("✓ Control flow CLIF generated successfully")
    catch e
        println("✗ Error: $e")
    end

    # Test 3: Even simpler control flow
    println("\n3. Minimal control flow:")
    function min_control(s::String)
        if sizeof(s) > 0
            return 1
        else
            return 0
        end
    end

    try
        interp = NativeCodegen.WasmCodegen.WasmInterp()
        clif = NativeCodegen.compile_to_clif(interp, min_control, Tuple{String})
        println(clif)
        println("✓ Minimal control flow CLIF generated successfully")
    catch e
        println("✗ Error: $e")
    end
end

println("\n=== CLIF Format Debug Complete ===")