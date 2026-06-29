# Debug: test allocation for internal use (no returning objects to Julia)
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_minimal.jl

using NativeCodegen

mutable struct Point
    x::Int64
    y::Int64
end

# Test 1: allocate Point, read fields, return computed Int64
# The Point never crosses back to Julia — only the Int64 result does.
function sf_new_compute(x::Int64, y::Int64)
    p = Point(x, y)
    return p.x * 100 + p.y  # 10*100 + 20 = 1020
end

println("=== Test 1: alloc + compute (no object return) ===")
try
    comp = compile_native(sf_new_compute, Tuple{Int64,Int64}; name="new_compute")
    nf = native_callable_from_so(comp, Int64, Int64, Int64)
    r = nf(Int64(10), Int64(20))
    expected = 10 * 100 + 20
    if r == expected
        println("✅ $r")
    else
        println("❌ got $r, expected $expected")
    end
    rm(comp.so_path)
catch e
    println("❌ $e")
end

# Test 2: allocate, use setfield!-like pattern (write then read)
function sf_new_swap(x::Int64, y::Int64)
    p = Point(x, y)
    # Use getfield to read the allocated fields
    a = p.x
    b = p.y
    return a * 1000 + b  # 10*1000 + 20 = 10020
end

println("\n=== Test 2: alloc + read fields ===")
try
    comp = compile_native(sf_new_swap, Tuple{Int64,Int64}; name="new_swap")
    nf = native_callable_from_so(comp, Int64, Int64, Int64)
    r = nf(Int64(10), Int64(20))
    expected = 10 * 1000 + 20
    if r == expected
        println("✅ $r")
    else
        println("❌ got $r, expected $expected")
    end
    rm(comp.so_path)
catch e
    println("❌ $e")
end
