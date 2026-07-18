# Debug simple return with getfield

using NativeCodegen

println("=== Debugging Simple Return with Getfield ===")

function simple_string_field(s::String)
    return getfield(s, :length)
end

println("\nGenerating CLIF for simple_string_field:")
try
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, simple_string_field, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end