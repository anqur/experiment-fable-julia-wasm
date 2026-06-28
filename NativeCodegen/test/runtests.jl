# NativeCodegen Phase 1 tests — scalar functions via native compilation.

using NativeCodegen
using Test

@testset "Integer arithmetic" begin
    add64(x::Int64, y::Int64) = x + y
    sub64(x::Int64, y::Int64) = x - y
    mul64(x::Int64, y::Int64) = x * y
    for (f, args, expected) in [(add64, (3, 4), 7), (sub64, (10, 3), 7), (mul64, (6, 7), 42)]
        comp = compile_native(f, Tuple{Int64, Int64})
        nf = native_callable(comp, Int64, Int64, Int64)
        @test nf(args...) == expected
    end
end

@testset "Boolean comparison" begin
    islarge(x::Int64) = x > 100
    comp = compile_native(islarge, Tuple{Int64})
    nf = native_callable(comp, Bool, Int64)
    @test nf(50) == false
    @test nf(200) == true
end

println("\n=== All Phase 1 tests passed ===")
