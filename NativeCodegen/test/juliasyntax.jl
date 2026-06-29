# JuliaSyntax integration tests for NativeCodegen

using NativeCodegen
using Test
using JuliaSyntax

@testset "JuliaSyntax basic tokenization" begin
    # Test basic tokenization function
    function test_tokenize(s::String)
        try
            tokens = JuliaSyntax.tokenize(s)
            return length(tokens)
        catch
            return -1
        end
    end

    # Try compiling a simple string processing function
    comp = compile_native(test_tokenize, Tuple{String})
    nf = native_callable(comp, Int64, String)

    # Test with simple input
    result = nf("x + y")
    @test result > 0  # Should return some token count

    println("JuliaSyntax basic test passed, tokens: $result")
end

@testset "JuliaSyntax parsing" begin
    # Test basic parsing function
    function test_parse(s::String)
        try
            ast = JuliaSyntax.parse(s, filename="test")
            return 1  # Success
        catch
            return -1  # Failure
        end
    end

    # Try compiling the parse function
    comp = compile_native(test_parse, Tuple{String})
    nf = native_callable(comp, Int64, String)

    # Test with simple Julia code
    result = nf("function f(x) x + 1 end")
    @test result == 1  # Should succeed

    println("JuliaSyntax parsing test passed")
end

@testset "String operations basic" begin
    # Test basic string operations
    function string_len_test(s::String)
        return length(s)
    end

    comp = compile_native(string_len_test, Tuple{String})
    nf = native_callable(comp, Int64, String)

    result = nf("hello world")
    @test result == 11

    println("String operations test passed, length: $result")
end

println("\n=== All JuliaSyntax integration tests passed ===")