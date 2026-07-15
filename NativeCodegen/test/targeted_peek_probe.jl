# targeted_peek_probe.jl — Targeted probe to confirm exact divergence point
#
# Finding: peek_token compiles, but peek (which calls peek_token) fails.
# This suggests the issue is in how peek's return value is handled.

using NativeCodegen
import Base.JuliaSyntax as JS

println("=" ^ 70)
println("TARGETED PEEK PROBE — Confirming exact divergence")
println("=" ^ 70)

# ============================================================================
# CONFIRMATION 1: peek_token compiles and can be called
# ============================================================================
println("\n=== CONFIRMATION 1: peek_token compiles ===")

f_peek_token_only(s::JS.ParseStream, k::Int) = begin
    tok = JS.peek_token(s, k)
    return tok  # Return the whole token
end

try
    comp = compile_native(f_peek_token_only, Tuple{JS.ParseStream, Int}; name="peek_token_only")
    println("✅ peek_token_only COMPILED")
    # Try calling it (should work)
    nf = native_callable_from_so(comp, Any, Tuple{JS.ParseStream, Int})
    ps = JS.ParseStream("1 + 2")
    result = nf(ps, 1)
    println("   ✅ peek_token_only CALL SUCCESS: ", typeof(result))
    rm(comp.so_path)
catch e
    println("❌ peek_token_only FAILED: ", e)
end

# ============================================================================
# CONFIRMATION 2: peek fails to compile
# ============================================================================
println("\n=== CONFIRMATION 2: peek fails to compile ===")

f_peek_only(s::JS.ParseStream) = begin
    tok = JS.peek(s)  # This internally calls peek_token
    return tok  # Return the whole token
end

try
    comp = compile_native(f_peek_only, Tuple{JS.ParseStream}; name="peek_only")
    println("✅ peek_only COMPILED (unexpected!)")
    rm(comp.so_path)
catch e
    println("❌ peek_only FAILED TO COMPILE: ", typeof(e).name)
end

# ============================================================================
# CONFIRMATION 3: What if we access fields after peek_token?
# ============================================================================
println("\n=== CONFIRMATION 3: peek_token + field access ===")

f_peek_token_with_field(s::JS.ParseStream, k::Int) = begin
    tok = JS.peek_token(s, k)
    return tok.head  # Access .head field
end

try
    comp = compile_native(f_peek_token_with_field, Tuple{JS.ParseStream, Int}; name="peek_token_field")
    println("✅ peek_token_with_field COMPILED")
    nf = native_callable_from_so(comp, Int64, Tuple{JS.ParseStream, Int})
    ps = JS.ParseStream("1 + 2")
    result = nf(ps, 1)
    println("   Result: ", result)
    rm(comp.so_path)
catch e
    println("❌ peek_token_with_field FAILED: ", e)
end

# ============================================================================
# CONFIRMATION 4: Host behavior check
# ============================================================================
println("\n=== CONFIRMATION 4: Host behavior ===")

ps = JS.ParseStream("1 + 2")
tok1 = JS.peek_token(ps, 1)
println("peek_token(ps, 1) type: ", typeof(tok1))
println("peek_token(ps, 1).head type: ", typeof(tok1.head))

peek_result = JS.peek(ps)
println("peek(ps) type: ", typeof(peek_result))
println("peek(ps) == peek_token(ps, 1): ", peek_result == tok1)

# ============================================================================
# CONFIRMATION 5: Check peek's source/IR
# ============================================================================
println("\n=== CONFIRMATION 5: peek method signature ===")

peek_methods = methods(JS.peek)
for m in peek_methods
    if m.sig == Tuple{typeof(JS.peek), JS.ParseStream}
        println("Found peek(ParseStream) method: ", m.sig)
        break
    end
end

println("\n" * "=" ^ 70)
println("CONCLUSION:")
println("The divergence is between peek_token (✅ compiles) and peek (❌ doesn't compile)")
println("This suggests the issue is in how peek wraps peek_token, not in peek_token itself")
println("=" ^ 70)
