# Direct call test to bypass closure issues

using NativeCodegen
using Libdl

println("=== Direct Call Test ===")

mutable struct DirectPoint
    x::Int64
    y::Int64
end

function direct_point()::DirectPoint
    return DirectPoint(100, 200)
end

println("Compiling function...")
try
    comp = compile_native(direct_point, Tuple{})
    println("✅ Compilation successful: ", comp.so_path)

    # Load the .so file directly
    lib = Libdl.dlopen(comp.so_path)
    println("✅ .so loaded")

    # Get the function symbol
    func = Libdl.dlsym(lib, "entry")
    println("✅ Function symbol loaded: ", func)

    # Call the function directly and get the raw pointer
    result_ptr = ccall(func, Ptr{Cvoid}, ())
    println("✅ Function returned pointer: ", result_ptr)

    if result_ptr != C_NULL
        println("✅ Got non-null pointer")

        # Try to convert to Julia object
        try
            julia_obj = unsafe_pointer_to_objref(result_ptr)
            println("✅ Converted to Julia object: ", julia_obj)
            println("   Type: ", typeof(julia_obj))

            if julia_obj isa DirectPoint
                println("✅ Object is correct type!")
                println("   x = ", julia_obj.x)
                println("   y = ", julia_obj.y)

                if julia_obj.x == 100 && julia_obj.y == 200
                    println("🎉 SUCCESS! Object header fix works!")
                else
                    println("❌ Field values incorrect")
                end
            else
                println("❌ Type mismatch: expected DirectPoint, got ", typeof(julia_obj))
            end
        catch e
            println("❌ Conversion failed: ", e)
            println("   This means the object header is still incompatible with Julia")
        end
    else
        println("❌ Function returned null pointer")
    end

    Libdl.dlclose(lib)
    rm(comp.so_path)

catch e
    println("❌ Error: ", e)
    for (exc, bt) in Base.catch_stack()
        showerror(stdout, exc, bt)
        println()
    end
end