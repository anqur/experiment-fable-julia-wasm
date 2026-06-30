# Simple test for struct allocation and return

using NativeCodegen
using Test

println("=== Simple Struct Return Test ===")

mutable struct SimplePoint
    x::Int64
    y::Int64
end

function simple_point()::SimplePoint
    return SimplePoint(10, 20)
end

println("Compiling simple_point function...")
try
    comp = compile_native(simple_point, Tuple{})
    println("✅ Compilation successful!")

    f = native_callable_from_so(comp, SimplePoint, Tuple{})
    println("✅ Function loaded successfully!")

    result = f()
    println("✅ Function executed successfully!")
    println("Result: $result")
    println("Type: $(typeof(result))")

    if result isa SimplePoint
        @test result.x == 10
        @test result.y == 20
        println("✅ All tests passed!")
    else
        println("❌ Type mismatch: expected SimplePoint, got $(typeof(result))")
    end

    rm(comp.so_path)
catch e
    println("❌ Error: $e")
    println("Error type: $(typeof(e))")
    for (exc, bt) in Base.catch_stack()
        showerror(stdout, exc, bt)
        println()
    end
end