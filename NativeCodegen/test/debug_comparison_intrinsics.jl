# Test: missing comparison intrinsics — sgt, sge, ugt, uge, gt_float, ge_float
using NativeCodegen
using Test

println("=== Priority 1: Comparison Intrinsics ===\n")

# --- Integer signed > and >= ---
println("--- signed integer comparisons ---")

@testset "sgt_int (signed >)" begin
    f(a::Int64, b::Int64) = a > b
    comp = compile_native(f, Tuple{Int64, Int64}; name="test_sgt")
    nf = native_callable_from_so(comp, Bool, Int64, Int64)
    @test nf(Int64(5), Int64(3)) == true
    @test nf(Int64(3), Int64(5)) == false
    @test nf(Int64(3), Int64(3)) == false
    rm(comp.so_path)
    println("  ✅ sgt works")
end

@testset "sge_int (signed >=)" begin
    f(a::Int64, b::Int64) = a >= b
    comp = compile_native(f, Tuple{Int64, Int64}; name="test_sge")
    nf = native_callable_from_so(comp, Bool, Int64, Int64)
    @test nf(Int64(5), Int64(3)) == true
    @test nf(Int64(3), Int64(3)) == true
    @test nf(Int64(3), Int64(5)) == false
    rm(comp.so_path)
    println("  ✅ sge works")
end

# --- Integer unsigned > and >= ---
println("--- unsigned integer comparisons ---")

@testset "ugt_int (unsigned >)" begin
    f(a::UInt64, b::UInt64) = a > b
    comp = compile_native(f, Tuple{UInt64, UInt64}; name="test_ugt")
    nf = native_callable_from_so(comp, Bool, UInt64, UInt64)
    @test nf(UInt64(5), UInt64(3)) == true
    @test nf(UInt64(3), UInt64(5)) == false
    @test nf(UInt64(3), UInt64(3)) == false
    rm(comp.so_path)
    println("  ✅ ugt works")
end

@testset "uge_int (unsigned >=)" begin
    f(a::UInt64, b::UInt64) = a >= b
    comp = compile_native(f, Tuple{UInt64, UInt64}; name="test_uge")
    nf = native_callable_from_so(comp, Bool, UInt64, UInt64)
    @test nf(UInt64(5), UInt64(3)) == true
    @test nf(UInt64(3), UInt64(3)) == true
    @test nf(UInt64(3), UInt64(5)) == false
    rm(comp.so_path)
    println("  ✅ uge works")
end

# --- Float > and >= ---
println("--- float comparisons ---")

@testset "gt_float (float >)" begin
    f(a::Float64, b::Float64) = a > b
    comp = compile_native(f, Tuple{Float64, Float64}; name="test_gt_float")
    nf = native_callable_from_so(comp, Bool, Float64, Float64)
    @test nf(5.0, 3.0) == true
    @test nf(3.0, 5.0) == false
    @test nf(3.0, 3.0) == false
    rm(comp.so_path)
    println("  ✅ gt_float works")
end

@testset "ge_float (float >=)" begin
    f(a::Float64, b::Float64) = a >= b
    comp = compile_native(f, Tuple{Float64, Float64}; name="test_ge_float")
    nf = native_callable_from_so(comp, Bool, Float64, Float64)
    @test nf(5.0, 3.0) == true
    @test nf(3.0, 3.0) == true
    @test nf(3.0, 5.0) == false
    rm(comp.so_path)
    println("  ✅ ge_float works")
end

println("\n=== All comparison intrinsics work! ===")
