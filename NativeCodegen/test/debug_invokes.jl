# Debug what invoke operations are being generated

using NativeCodegen

println("=== Debugging Invoke Operations ===")

# Test 1: isempty
function string_isempty(s::String)
    return isempty(s)
end

println("1. isempty(String):")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_isempty, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end

# Test 2: first
function string_first(s::String)
    return first(s)
end

println("\n2. first(String):")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_first, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end

# Test 3: last
function string_last(s::String)
    return last(s)
end

println("\n3. last(String):")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_last, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end