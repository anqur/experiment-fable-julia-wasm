# Test: continue statement and memory load in while loop
using NativeCodegen
import Base.JuliaSyntax as JuliaSyntax

println("=== Memory Load + Conditional in Loop Tests ===\n")

# Test 1: Continue with hex literal
function count_non_us(src::Ptr{UInt8}, len::Int)::Int
    n = 0; i = 0
    while i < len
        b = unsafe_load(src + i)
        i += 1
        if b == UInt8(0x5f); continue; end  # '_' = 0x5f
        n += 1
    end
    return n
end

buf = Vector{UInt8}("a_b_c")
print("Test 1 (hex literal + continue): ")
comp = compile_native(count_non_us, Tuple{Ptr{UInt8}, Int}; name="t1")
nf = native_callable_from_so(comp, Int, Ptr{UInt8}, Int)
got = nf(pointer(buf), Int(length(buf)))
expected = count_non_us(pointer(buf), length(buf))
println("got $got, expected $expected, $(got==expected ? "✅" : "❌")")
rm(comp.so_path)

# Test 2: _copy_normalize_number! (strips underscore from "1_000.5")
println("\nTest 2 (_copy_normalize_number!):")
src_bytes = Vector{UInt8}("1_000.5")
dst_bytes = Vector{UInt8}(undef, 10)
host_n = JuliaSyntax._copy_normalize_number!(pointer(dst_bytes), pointer(src_bytes), length(src_bytes))
println("  Host: n=$host_n, dst='$(String(dst_bytes[1:host_n]))'")

comp2 = compile_native(JuliaSyntax._copy_normalize_number!, Tuple{Ptr{UInt8}, Ptr{UInt8}, Int}; name="t2")
nf2 = native_callable_from_so(comp2, Int64, Ptr{UInt8}, Ptr{UInt8}, Int64)
dst2 = Vector{UInt8}(undef, 10)
got_n = nf2(pointer(dst2), pointer(src_bytes), Int64(length(src_bytes)))
println("  Native: n=$got_n, dst='$(String(dst2[1:got_n]))' $(got_n==host_n ? "✅" : "❌")")
rm(comp2.so_path)

# Test 3: Array access + conditional in loop
function arr_skip(arr::Vector{UInt8})::Int
    n = 0; i = 0; len = length(arr)
    while i < len
        i += 1
        b = arr[i]
        if b == UInt8(0x5f); continue; end
        n += 1
    end
    return n
end

arr = Vector{UInt8}("a_b_c")
print("\nTest 3 (array access + continue): ")
comp3 = compile_native(arr_skip, Tuple{Vector{UInt8}}; name="t3")
nf3 = native_callable_from_so(comp3, Int, Vector{UInt8})
got3 = nf3(arr)
expected3 = arr_skip(arr)
println("got $got3, expected $expected3, $(got3==expected3 ? "✅" : "❌")")
rm(comp3.so_path)

println("\n=== All loop tests complete! ===")
