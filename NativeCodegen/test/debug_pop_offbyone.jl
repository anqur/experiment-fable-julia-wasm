using NativeCodegen
using NativeCodegen: compile_and_call

println("=== pop! off-by-one investigation ===")

# Actual pop! on various sizes
popone(a::Vector{Int64}) = pop!(a)

for arr in [Int64[10,20,30], Int64[10,20], Int64[10,20,30,40,50]]
    expected = arr[end]
    print("  popone $arr ... ")
    try
        test_arr = copy(arr)
        r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, test_arr)
        println(r == expected ? "✅ $r" : "❌ expected $expected, got $r (arr after: $test_arr)")
    catch e
        println("❌ ", e)
    end
end
