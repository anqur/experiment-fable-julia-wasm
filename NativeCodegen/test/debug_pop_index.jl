using NativeCodegen
using NativeCodegen: compile_and_call

println("=== pop! diagnostic ===")

# Simpler: just read last element at index=length(a)
readlast(a::Vector{Int64}) = a[length(a)]
print("  readlast [10,20,30] ... ")
try
    r = compile_and_call(readlast, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end

# Read at specific index
readat2(a::Vector{Int64}) = a[2]
print("  readat2 [10,20,30] ... ")
try
    r = compile_and_call(readat2, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 20 ? "✅ $r" : "❌ expected 20, got $r")
catch e
    println("❌ ", e)
end

readat3(a::Vector{Int64}) = a[3]
print("  readat3 [10,20,30] ... ")
try
    r = compile_and_call(readat3, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end
