# Debug pointer type detection

using NativeCodegen

println("=== Testing _is_ptr_type ===")

types_to_test = [
    Int64, Float64,
    Tuple{Int64, Int64}, Tuple{Int64, Float64}, Tuple{Int64},
    String, Vector{Int64},
    Ptr{UInt8}
]

for T in types_to_test
    result = NativeCodegen._is_ptr_type(T)
    println("_is_ptr_type($T): $result")
end

println("\n=== Testing scalar_repr (should return nothing for tuples) ===")
using WasmCodegen: scalar_repr

for T in types_to_test
    result = scalar_repr(T)
    println("scalar_repr($T): $result")
end