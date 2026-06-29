# Debug string comparison CLIF generation

using NativeCodegen

println("=== Debugging String Comparison CLIF ===")

function string_eq(s1::String, s2::String)
    return s1 == s2
end

println("Generating CLIF for string_eq:")
interp = NativeCodegen.WasmCodegen.WasmInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, string_eq, Tuple{String, String})
    println("Generated CLIF:")
    println(clif)

    println("\nLine-by-line:")
    lines = split(clif, '\n')
    for (i, line) in enumerate(lines)
        println("Line $i: \"$line\"")
    end
catch e
    println("Error generating CLIF: $e")
end