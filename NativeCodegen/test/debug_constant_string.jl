# Debug constant string handling

using NativeCodegen

function make_string()
    return "hello"
end

println("Checking CLIF for constant string return:")
interp = NativeCodegen.NCGInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, make_string, Tuple{})
    println(clif)
catch e
    println("Error: $e")
end