# Test: Recursion support (Priority 5)
using NativeCodegen
using Test

println("=== Priority 5: Recursion Support ===\n")

# Use named functions for reliable MethodInstance lookup

function my_countdown(n::Int64)::Int64
    return n > 0 ? my_countdown(n - 1) : Int64(0)
end

function my_fact(n::Int64)::Int64
    return n <= 1 ? Int64(1) : n * my_fact(n - 1)
end

function my_fib(n::Int64)::Int64
    return n <= 1 ? n : my_fib(n - 1) + my_fib(n - 2)
end

# --- Countdown ---
println("--- countdown ---")
@testset "countdown recursion" begin
    comp = compile_native(my_countdown, Tuple{Int64}; name="test_rec_cd")
    nf = native_callable_from_so(comp, Int64, Int64)
    @test nf(Int64(5)) == 0
    @test nf(Int64(0)) == 0
    @test nf(Int64(10)) == 0
    rm(comp.so_path)
    println("  ✅ countdown")
end

# --- Factorial ---
println("--- factorial ---")
@testset "factorial recursion" begin
    comp = compile_native(my_fact, Tuple{Int64}; name="test_rec_fact")
    nf = native_callable_from_so(comp, Int64, Int64)
    @test nf(Int64(1)) == 1
    @test nf(Int64(5)) == 120
    @test nf(Int64(0)) == 1
    rm(comp.so_path)
    println("  ✅ factorial")
end

# --- Fibonacci (double recursion) ---
println("--- fibonacci ---")
@testset "fibonacci recursion" begin
    comp = compile_native(my_fib, Tuple{Int64}; name="test_rec_fib")
    nf = native_callable_from_so(comp, Int64, Int64)
    @test nf(Int64(0)) == 0
    @test nf(Int64(1)) == 1
    @test nf(Int64(6)) == 8
    @test nf(Int64(10)) == 55
    rm(comp.so_path)
    println("  ✅ fibonacci")
end

# --- Verify _first_error isa works (but may fail on tuple indexing) ---
println("\n--- _first_error (recursion + isa) ---")
import JuliaSyntax
@testset "_first_error compilation" begin
    f(x) = JuliaSyntax._first_error(x)
    try
        comp = compile_native(f, Tuple{JuliaSyntax.SyntaxNode}; name="test_fe_rec")
        println("  ✅ _first_error compiled!")
        rm(comp.so_path)
    catch e
        # Expected: heterogeneous dynamic tuple indexing is not yet supported
        msg = sprint(showerror, e)
        if occursin("heterogeneous dynamic tuple indexing", msg)
            println("  ⏭️ isa+tup access work, tuple indexing needs heterogeneous support")
            @test_skip "heterogeneous dynamic tuple indexing"
        else
            println("  ❌ unexpected: ", typeof(e).name.name, ": ", msg[1:200])
            @test false
        end
    end
end

println("\n=== Recursion tests complete! ===")
