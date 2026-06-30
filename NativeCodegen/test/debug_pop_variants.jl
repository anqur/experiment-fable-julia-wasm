using NativeCodegen
using NativeCodegen: compile_and_call

println("=== pop! variants ===")

# Minimal: just return last element (already works)
readlast(a::Vector{Int64}) = a[length(a)]
print("  readlast [10,20,30] ... ")
try
    r = compile_and_call(readlast, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end

# Minimal pop-like: read last, then setfield size
function fakepop(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    resize!(a, n-1)
    v
end
print("  fakepop [10,20,30] ... ")
try
    r = compile_and_call(fakepop, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end

# Actual pop!
popone(a::Vector{Int64}) = pop!(a)
print("  popone [10,20,30] ... ")
try
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end

# pop! with 2-element array
print("  popone [10,20] ... ")
try
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, Int64[10,20])
    println(r == 20 ? "✅ $r" : "❌ expected 20, got $r")
catch e
    println("❌ ", e)
end

# pop! with 1-element array
print("  popone [42] ... ")
try
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, Int64[42])
    println(r == 42 ? "✅ $r" : "❌ expected 42, got $r")
catch e
    println("❌ ", e)
end
