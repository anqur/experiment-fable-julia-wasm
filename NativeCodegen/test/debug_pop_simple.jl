using NativeCodegen
using NativeCodegen: compile_and_call

println("=== Simplified pop variants ===")

# Simplified pop - just read and return last element, no resize
function simple_pop(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    v
end

print("  simple_pop [10,20,30] ... ")
try
    r = compile_and_call(simple_pop, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end

# Even simpler - inline the length
function simpler_pop(a::Vector{Int64})
    @inbounds v = a[length(a)]
    v
end

print("  simpler_pop [10,20,30] ... ")
try
    r = compile_and_call(simpler_pop, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end
