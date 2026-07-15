# debug_peek_token_simple.jl — Test if peek_token can be compiled standalone
using NativeCodegen
import Base.JuliaSyntax as JS

println("=== Test: Can we compile peek_token directly? ===")

# Test 1: Compile peek_token with k=1
f_pt1(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 1)
    return Int64(reinterpret(UInt32, tok.head))
end

ps = JS.ParseStream("1 + 2")

println("Host result: ", f_pt1(ps))

try
    println("Compiling native...")
    comp = compile_native(f_pt1, Tuple{JS.ParseStream}; name="peek_token_k1")
    println("Compilation succeeded!")
    nf = native_callable_from_so(comp, Int64, Tuple{JS.ParseStream})
    flush(stdout)
    println("Calling native...")
    result = nf(ps)
    flush(stdout)
    println("Native result: ", result)
    rm(comp.so_path)
    println("✅ SUCCESS")
catch e
    println("❌ FAILED: ", e)
end
