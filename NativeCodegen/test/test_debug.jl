# Debug test to understand the closure issue

using NativeCodegen
using Libdl

println("=== Debug Test ===")

# First, let's test if we can even create the compilation
mutable struct DebugPoint
    x::Int64
    y::Int64
end

function debug_point()::DebugPoint
    return DebugPoint(5, 10)
end

println("Creating compilation...")
try
    comp = compile_native(debug_point, Tuple{})
    println("✅ Compilation successful")

    println("Loading .so file...")
    lib = Libdl.dlopen(comp.so_path)
    func_ptr = Libdl.dlsym(lib, comp.func_name)
    println("✅ Function loaded: ", func_ptr)

    println("Creating closure with native_callable_from_so...")
    f = native_callable(comp, DebugPoint, Tuple{})
    println("✅ Closure created")

    println("Closure type: ", typeof(f))

    println("Calling closure...")
    result = f()
    println("✅ Success! Result: ", result)

    rm(comp.so_path)
catch e
    println("❌ Error: ", e)
    println("Error type: ", typeof(e))
    for (exc, bt) in Base.catch_stack()
        showerror(stdout, exc, bt)
        println()
    end
end