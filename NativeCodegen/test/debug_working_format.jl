# Debug working CLIF format

using NativeCodegen

println("=== Examining Working CLIF Format ===")

function working_sizeof(s::String)
    return sizeof(s)
end

println("Working sizeof function:")
interp = NativeCodegen.NCGInterp()
clif1 = NativeCodegen.compile_to_clif(interp, working_sizeof, Tuple{String})
println(clif1)

println("\nTrying to compile working function:")
try
    comp = compile_native(working_sizeof, Tuple{String})
    nf = native_callable(comp, Int64, String)
    result = nf("hello")
    println("✓ Working function compiles and runs! Result: $result")
catch e
    println("✗ Error: $e")
end

println("\n" * "="^60)
println("Comparing with broken control flow:")

function broken_control(s::String)
    if sizeof(s) > 3
        return 1
    else
        return 0
    end
end

println("\nBroken control flow function:")
try
    clif2 = NativeCodegen.compile_to_clif(interp, broken_control, Tuple{String})
    println(clif2)

    println("\nTrying to compile broken function:")
    comp = compile_native(broken_control, Tuple{String})
    println("✓ Broken function compiles!")
catch e
    println("✗ Error: $e")
end