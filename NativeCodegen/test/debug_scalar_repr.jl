# Debug scalar_repr issues

using NativeCodegen
using WasmCodegen: scalar_repr

println("=== Testing scalar_repr on common types ===")

types_to_test = [
    Int64, Float64, Int32, Float32, Bool, Char,
    Tuple{Int64, Int64}, Tuple{Int64, Float64},
    String, Vector{Int64},
    Ptr{UInt8}
]

for T in types_to_test
    result = scalar_repr(T)
    println("$T: $result")
    if result !== nothing
        try
            println("  bits: $(result.bits)")
            println("  isfloat: $(result.isfloat)")
        catch e
            println("  Error accessing fields: $e")
        end
    end
end