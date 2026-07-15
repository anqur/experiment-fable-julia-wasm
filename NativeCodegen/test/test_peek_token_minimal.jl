# test_peek_token_minimal.jl - Minimal test to isolate peek_token crash

using NativeCodegen
using Libdl
import Base.JuliaSyntax as JS

println("=== Minimal peek_token test ===")

# Test 1: Check if peek_token compiles at all
println("\n1. Testing peek_token compilation...")
f_peek_token(ps::JS.ParseStream) = JS.peek_token(ps)
ps = JS.ParseStream("1 + 2")

try
    println("  Compiling peek_token...")
    comp = compile_native(f_peek_token, Tuple{JS.ParseStream}; name="peek_token_minimal")
    println("  Compilation succeeded!")

    println("  Running native version...")
    nf = native_callable_from_so(comp, typeof(f_peek_token(ps)), Tuple{JS.ParseStream})
    flush(stdout)
    tok = nf(ps)
    println("  Execution succeeded!")
    println("  Result: ", tok)

    rm(comp.so_path)
catch e
    if e isa InterruptException
        rethrow()
    end
    println("  ERROR: ", sprint(showerror, e))
end

# Test 2: Check if _buffer_lookahead_tokens compiles
println("\n2. Testing _buffer_lookahead_tokens compilation...")
f_buffer(src::String) = begin
    ps = JS.ParseStream(src)
    JS._buffer_lookahead_tokens(ps.lexer, ps.lookahead, 2)
    return Int64(length(ps.lookahead))
end

try
    println("  Compiling _buffer_lookahead_tokens...")
    comp = compile_native(f_buffer, Tuple{String}; name="buffer_minimal")
    println("  Compilation succeeded!")

    println("  Running native version...")
    nf = native_callable_from_so(comp, Int64, Tuple{String})
    flush(stdout)
    len = nf("1 + 2")
    println("  Execution succeeded!")
    println("  Result: ", len)

    rm(comp.so_path)
catch e
    if e isa InterruptException
        rethrow()
    end
    println("  ERROR: ", sprint(showerror, e))
end

# Test 3: Check if next_token compiles
println("\n3. Testing next_token compilation...")
f_next_token(src::String) = begin
    ps = JS.ParseStream(src)
    return JS.next_token(ps.lexer)
end

try
    println("  Compiling next_token...")
    comp = compile_native(f_next_token, Tuple{String}; name="next_token_minimal")
    println("  Compilation succeeded!")

    println("  Running native version...")
    nf = native_callable_from_so(comp, typeof(f_next_token("1")), Tuple{String})
    flush(stdout)
    tok = nf("1")
    println("  Execution succeeded!")
    println("  Result: ", tok)

    rm(comp.so_path)
catch e
    if e isa InterruptException
        rethrow()
    end
    println("  ERROR: ", sprint(showerror, e))
end

println("\n=== Summary ===")
println("Check above for which function failed")
