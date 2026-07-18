# Debug String field CLIF generation

using NativeCodegen

println("=== Debugging String Field CLIF Generation ===")

function string_length_field(s::String)
    l = getfield(s, :length)
    return l
end

println("\nGenerating CLIF for string_length_field:")
try
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, string_length_field, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
    println("Stack trace:")
    for (i, frame) in enumerate(stacktrace(catch_backtrace()))
        println("  $i: $frame")
    end
end