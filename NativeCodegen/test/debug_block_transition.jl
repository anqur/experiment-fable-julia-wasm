# Debug block transition issues

using NativeCodegen

println("=== Debugging Block Transition Issues ===")

function simple_control(s::String)
    if sizeof(s) > 3
        return 1
    else
        return 0
    end
end

println("Generating CLIF for simple_control:")
interp = NativeCodegen.WasmCodegen.WasmInterp()
clif = NativeCodegen.compile_to_clif(interp, simple_control, Tuple{String})

println("CLIF output:")
println(clif)

println("\nLine-by-line analysis:")
lines = split(clif, '\n')
for (i, line) in enumerate(lines)
    println("Line $i: \"$line\"")
end

println("\nTrying to compile...")
try
    comp = compile_native(simple_control, Tuple{String})
    println("✓ Compilation succeeded!")
catch e
    println("✗ Compilation failed: $e")
end