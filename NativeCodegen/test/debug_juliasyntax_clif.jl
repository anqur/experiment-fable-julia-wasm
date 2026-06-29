# Debug JuliaSyntax compilation issues

using NativeCodegen
using JuliaSyntax

println("=== Debugging JuliaSyntax Compilation ===")

# Test 1: Check what CLIF is generated for tokenize
function simple_tokenize(input::String)
    try
        tokens = JuliaSyntax.tokenize(input)
        return length(tokens)
    catch e
        return -1
    end
end

println("\n1. tokenize function CLIF:")
interp = NativeCodegen.WasmCodegen.WasmInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, simple_tokenize, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end

# Test 2: Check identity_string
function identity_string(s::String)
    return s
end

println("\n2. identity_string function CLIF:")
try
    clif = NativeCodegen.compile_to_clif(interp, identity_string, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end

# Test 3: Check string comparison
function string_eq(s1::String, s2::String)
    return s1 == s2
end

println("\n3. string_eq function CLIF:")
try
    clif = NativeCodegen.compile_to_clif(interp, string_eq, Tuple{String, String})
    println(clif)
catch e
    println("Error: $e")
end

println("\n=== Debug Complete ===")