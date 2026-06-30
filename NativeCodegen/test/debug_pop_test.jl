using NativeCodegen
using NativeCodegen: compile_and_call

println("=== pop! test ===")
popone(a::Vector{Int64}) = (x = pop!(a); x)
print("  popone ... ")
try
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, Int64[10,20,30])
    println(r == 30 ? "✅ $r" : "❌ expected 30, got $r")
catch e
    println("❌ ", e)
end
