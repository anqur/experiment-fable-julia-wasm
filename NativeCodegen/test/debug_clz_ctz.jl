# Test: sub-word clz/ctz/ctpop correction (Priority 3)
# clz on UInt8/UInt16 stored as i32 counts docs 32 leading zeros,
# so we subtract padding bits: clz(x, T) = clz(x) - (32 - 8*sizeof(T)).
using NativeCodegen
using Test

println("=== Priority 3: Sub-word clz/ctz/ctpop Correction ===\n")

# --- clz on sub-word types ---
println("--- clz (leading_zeros) ---")

@testset "clz on UInt8" begin
    f(x::UInt8) = Base.leading_zeros(x)
    comp = compile_native(f, Tuple{UInt8}; name="test_clz_u8")
    nf = native_callable_from_so(comp, Int64, UInt8)
    @test nf(UInt8(0x00)) == 8   # all zeros → 8 leading zeros
    @test nf(UInt8(0x01)) == 7   # 0b00000001 → 7
    @test nf(UInt8(0x80)) == 0   # 0b10000000 → 0
    @test nf(UInt8(0xFF)) == 0   # all ones → 0
    rm(comp.so_path)
    println("  ✅ clz on UInt8 works")
end

@testset "clz on UInt16" begin
    f(x::UInt16) = Base.leading_zeros(x)
    comp = compile_native(f, Tuple{UInt16}; name="test_clz_u16")
    nf = native_callable_from_so(comp, Int64, UInt16)
    @test nf(UInt16(0x0000)) == 16  # all zeros → 16 leading zeros
    @test nf(UInt16(0x0001)) == 15  # 0b0000_0000_0000_0001 → 15
    @test nf(UInt16(0x8000)) == 0   # 0b1000_0000_0000_0000 → 0
    @test nf(UInt16(0x00FF)) == 8   # 0b0000_0000_1111_1111 → 8
    rm(comp.so_path)
    println("  ✅ clz on UInt16 works")
end

@testset "clz on full-width types (no correction needed)" begin
    f(x::Int64) = Base.leading_zeros(x)
    comp = compile_native(f, Tuple{Int64}; name="test_clz_i64")
    nf = native_callable_from_so(comp, Int64, Int64)
    @test nf(Int64(0)) == 64
    @test nf(Int64(1)) == 63
    @test nf(Int64(-1)) == 0
    rm(comp.so_path)
    println("  ✅ clz on Int64 works (no correction)")
end

# --- ctz (already correct for zero-extended values) ---
println("--- ctz (trailing_zeros) ---")

@testset "ctz on UInt8" begin
    f(x::UInt8) = Base.trailing_zeros(x)
    comp = compile_native(f, Tuple{UInt8}; name="test_ctz_u8")
    nf = native_callable_from_so(comp, Int64, UInt8)
    @test nf(UInt8(0x00)) == 8   # Julia convention: result = bitwidth for zero
    @test nf(UInt8(0x01)) == 0
    @test nf(UInt8(0x10)) == 4
    @test nf(UInt8(0x80)) == 7
    rm(comp.so_path)
    println("  ✅ ctz on UInt8 works (no correction needed)")
end

# --- ctpop (already correct for zero-extended values) ---
println("--- ctpop (count_ones) ---")

@testset "ctpop on UInt8" begin
    f(x::UInt8) = Base.count_ones(x)
    comp = compile_native(f, Tuple{UInt8}; name="test_ctpop_u8")
    nf = native_callable_from_so(comp, Int64, UInt8)
    @test nf(UInt8(0x00)) == 0
    @test nf(UInt8(0x01)) == 1
    @test nf(UInt8(0xFF)) == 8
    @test nf(UInt8(0xAA)) == 4  # 0b10101010 → 4 ones
    rm(comp.so_path)
    println("  ✅ ctpop on UInt8 works (no correction needed)")
end

println("\n=== All bit-count ops correct for sub-word types! ===")
