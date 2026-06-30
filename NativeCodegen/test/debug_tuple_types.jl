# Debug tuple type handling

using NativeCodegen

println("=== Debugging Tuple Types ===")

# Test basic tuple properties
T1 = Tuple{Int64, Int64}
println("Tuple{Int64, Int64}:")
println("  isbitstype: ", isbitstype(T1))
println("  sizeof: ", sizeof(T1))
println("  Base.ismutabletype: ", Base.ismutabletype(T1))

T2 = Tuple{Int64, Float64, Int64}
println("Tuple{Int64, Float64, Int64}:")
println("  isbitstype: ", isbitstype(T2))
println("  sizeof: ", sizeof(T2))

T3 = Tuple{Int64}
println("Tuple{Int64}:")
println("  isbitstype: ", isbitstype(T3))
println("  sizeof: ", sizeof(T3))

# Test cranelift_type function
println("\n=== Testing cranelift_type ===")
try
    result = NativeCodegen.cranelift_type(T1)
    println("cranelift_type(Tuple{Int64, Int64}): $result")
catch e
    println("Error: $e")
end

try
    result = NativeCodegen.cranelift_type(T3)
    println("cranelift_type(Tuple{Int64}): $result")
catch e
    println("Error: $e")
end