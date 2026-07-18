# Debug string operations

using NativeCodegen

println("=== Debug String Operations ===")

# Test 1: Check CLIF generation for sizeof(String)
function string_sizeof_test(s::String)
    return sizeof(s)
end

println("\n1. Testing sizeof(String):")
interp = NativeCodegen.NCGInterp()
try
    clif = NativeCodegen.compile_to_clif(interp, string_sizeof_test, Tuple{String})
    println("Generated CLIF:")
    println(clif)
catch e
    println("Error generating CLIF: $e")
end

# Test 2: Try to compile and run
println("\n2. Testing compilation:")
try
    comp = compile_native(string_sizeof_test, Tuple{String})
    nf = native_callable(comp, Int64, String)
    println("Compilation succeeded!")

    test_str = "hello"
    println("Testing with string: \"$test_str\"")
    result = nf(test_str)
    println("Result: $result")
    println("Expected: $(sizeof(test_str))")
catch e
    println("Error: $e")
    println("Stack trace:")
    for (exc, bt) in Base.catch_stack()
        showerror(IOContext(stderr, :backtrace => bt), exc)
        println(stderr)
    end
end

println("\n=== Debug Complete ===")