# Debug string processing CLIF generation

using NativeCodegen

println("=== Debugging String Processing CLIF ===")

function process_string(s::String)
    sz = sizeof(s)
    # Simple processing based on size
    if sz > 3
        return 1
    else
        return 0
    end
end

println("\nGenerating CLIF for process_string:")
try
    interp = NativeCodegen.NCGInterp()
    clif = NativeCodegen.compile_to_clif(interp, process_string, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end