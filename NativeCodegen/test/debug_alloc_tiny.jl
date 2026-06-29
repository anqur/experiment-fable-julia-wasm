# Minimal allocation test — try to catch the actual error
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_tiny.jl

using NativeCodegen

function alloc_vec(n::Int64)
    return Vector{Int64}(undef, n)
end

try
    comp = compile_native(alloc_vec, Tuple{Int64}; name="alloc_tiny")
    println("Compilation OK: $(comp.so_path)")

    # Load the .so and try to call
    lib = Libdl.dlopen(comp.so_path)
    func_ptr = Libdl.dlsym(lib, "alloc_tiny")
    println("Function pointer: $func_ptr")

    # Call with n=3
    n = Int64(3)
    println("Calling with n=$n...")
    result = ccall(func_ptr, Int64, (Int64,), n)
    println("Result: $result")
catch e
    println("Error type: $(typeof(e))")
    println("Error: $e")
    # Try to get stack trace
    try
        for (exc, bt) in Base.catch_stack()
            showerror(stderr, exc, bt)
            println(stderr)
        end
    catch
    end
end
