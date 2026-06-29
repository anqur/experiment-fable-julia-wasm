# Check invoke CLIF generation

using NativeCodegen

function string_length_test(s::String)
    return length(s)
end

println("Checking CLIF for length(String):")
interp = NativeCodegen.WasmCodegen.WasmInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, string_length_test, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end