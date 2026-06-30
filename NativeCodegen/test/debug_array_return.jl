# Probe array-return variants to isolate the loop-CFG phi bug from the allocator.
using NativeCodegen

function alloc_uninit()::Vector{Int64}
    return Vector{Int64}(undef, 4)
end

for (name, f) in [("uninit(undef,4)", alloc_uninit)]
    println("\n--- $name ---")
    try
        r = compile_and_call(f, Vector{Int64}, Tuple{})
        println("OK: typeof=$(typeof(r)) length=$(length(r))")
    catch e
        println("ERR: $e")
    end
end
