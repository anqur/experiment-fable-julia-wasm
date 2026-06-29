# Test simple CLIF generation without control flow

using NativeCodegen

function simple_add(a::Int, b::Int)
    return a + b
end

println("=== Simple CLIF (no control flow) ===")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, simple_add, Tuple{Int, Int})
    println(clif)
catch e
    println("Error: $e")
end

function simple_if(a::Int)
    if a > 0
        return 1
    else
        return 0
    end
end

println("\n=== Simple CLIF (with if/else) ===")
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    clif = NativeCodegen.compile_to_clif(interp, simple_if, Tuple{Int})
    println(clif)
catch e
    println("Error: $e")
end