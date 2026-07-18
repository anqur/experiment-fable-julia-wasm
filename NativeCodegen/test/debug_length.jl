# Debug length function

using NativeCodegen

function string_length_test(s::String)
    return length(s)
end

println("Generating CLIF for length function:")
interp = NativeCodegen.NCGInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, string_length_test, Tuple{String})
    println(clif)
catch e
    println("Error: $e")
end