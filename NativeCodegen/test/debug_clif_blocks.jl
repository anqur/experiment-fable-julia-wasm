# Debug CLIF block formatting issue

using NativeCodegen

function test_combined(s::String)
    if isempty(s)
        return 0
    else
        return ncodeunits(s) + lastindex(s)
    end
end

println("=== Testing CLIF Generation for Combined Operations ===")

try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, test_combined, Tuple{String})
    println("Generated CLIF:")
    println(clif)
    println("\n=== CLIF Generation Complete ===")
catch e
    println("Error generating CLIF: $e")
end