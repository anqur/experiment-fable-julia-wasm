# Debug string equality CLIF with ===

using NativeCodegen

println("=== Debugging === CLIF ===")

function string_eq_simple(s1::String, s2::String)
    return s1 === s2
end

println("Generating CLIF for s1 === s2:")
interp = NativeCodegen.NCGInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, string_eq_simple, Tuple{String, String})
    println("Generated CLIF:")
    println(clif)
catch e
    println("Error: $e")
end