# Debug allocation crash — try to isolate the issue
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_crash.jl

using NativeCodegen

# Test 1: simpler allocation — just allocate, no store (bypass %new by returning nothing)
# But we can't easily bypass %new in the IR...
# Let's instead check if the linker is including the runtime properly

function alloc_vec(n::Int64)
    return Vector{Int64}(undef, n)
end

println("---")
println("sizeof(Vector{Int64}): ", sizeof(Vector{Int64}))
println("sizeof(MemoryRef{Int64}): ", sizeof(MemoryRef{Int64}))

try
    comp = compile_native(alloc_vec, Tuple{Int64}; name="alloc_crash")
    println("Compilation OK, SO: $(comp.so_path)")

    # Use objdump to see the generated code
    so = comp.so_path
    run(`otool -tV $so 2>&1 | head -80`)
catch e
    println("Error: $e")
end
