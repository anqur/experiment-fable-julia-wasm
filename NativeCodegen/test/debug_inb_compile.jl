# Debug: Compile @inbounds a[i] with stack trace
# Usage: julia +nightly --project=. NativeCodegen/test/debug_inb_compile.jl

using NativeCodegen

function ar_inb_get(a::Vector{Int64},i::Int64)
    @inbounds r = a[i]
    return r
end

try
    comp = compile_native(ar_inb_get, Tuple{Vector{Int64}, Int64}; name="inb2")
    nf = native_callable_from_so(comp, Int64, Vector{Int64}, Int64)
    r = nf(Int64[10,20,30,40], Int64(2))
    println("Result: ", r)
catch e
    println("Error: ", e)
    for (exc, bt) in Base.catch_stack()
        println(stderr, "---")
        showerror(stderr, exc, bt)
        println(stderr)
    end
end
