# Check if runtime symbols are in the compiled .so
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_symbols.jl

using NativeCodegen

function f(n::Int64)
    return Vector{Int64}(undef, n)
end

try
    comp = compile_native(f, Tuple{Int64}; name="alloc_test")
    so = comp.so_path
    println("SO path: $so")
    # Check symbols
    run(`nm $so`)
catch e
    println("Compile error: $e")
end
