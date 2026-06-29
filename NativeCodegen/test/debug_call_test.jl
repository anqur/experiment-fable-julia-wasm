# Verify call mechanism works — test direct lib call and compiled call
# Usage: julia +nightly --project=. NativeCodegen/test/debug_call_test.jl

using NativeCodegen, Libdl

# Test 1: compile a simple function that returns a constant (baseline — works)
# Test 2: call __jl_gc_alloc directly from a compiled .so

# First verify the runtime functions are callable from a .so
# by compiling a function and loading the .so
function simple(n::Int64)
    return n + 1
end

comp = compile_native(simple, Tuple{Int64}; name="simple_test")
lib = Libdl.dlopen(comp.so_path)
println("Simple function compiled OK")

# Check if __jl_gc_alloc is in the .so
sym = Libdl.dlsym_e(lib, "__jl_gc_alloc")
println("__jl_gc_alloc in .so: $(sym != C_NULL)")

# Try calling __jl_gc_alloc from the .so directly
if sym != C_NULL
    result = ccall(sym, Ptr{Cvoid}, (UInt32, UInt32), UInt32(3), UInt32(24))
    println("Direct __jl_gc_alloc(3, 24) = $result")
    println("Result is null? $(result == C_NULL)")
end
