# compile_only_peek_probes.jl — Compile-only probes to find first native-vs-host divergence
#
# Strategy: Compile each operation and exit without calling, to identify
# where compilation first diverges from host behavior (crashes on runtime)
#
# This is read-only: we only compile, we don't call the .so

using NativeCodegen
import Base.JuliaSyntax as JS
using Core.Compiler

println("=" ^ 70)
println("COMPILE-ONLY PEEK PROBES — Finding first compilation divergence")
println("=" ^ 70)

# Helper to try compilation and report success/failure
function try_compile(name, f, argT)
    print("  $name ... ")
    flush(stdout)
    try
        comp = compile_native(f, argT; name=name)
        println("✅ Compilation succeeded")
        # Clean up .so file without calling it
        try
            rm(comp.so_path)
        catch
        end
        return true
    catch e
        if e isa InterruptException
            rethrow()
        end
        println("❌ Compilation failed: ", typeof(e).name)
        return false
    end
end

# ============================================================================
# LEVEL 0: Baseline - Can we compile anything at all?
# ============================================================================
println("\n=== LEVEL 0: Baseline compilation ===")

f_add(x::Int64) = x + 1
try_compile("baseline_add_int", f_add, Tuple{Int64})

f_create_stream() = JS.ParseStream("1")
try_compile("baseline_create_stream", f_create_stream, Tuple{})

# ============================================================================
# LEVEL 1: Simple ParseStream field access
# ============================================================================
println("\n=== LEVEL 1: Simple ParseStream field access ===")

f_read_next_byte(s::JS.ParseStream) = Int64(s.next_byte)
try_compile("read_next_byte", f_read_next_byte, Tuple{JS.ParseStream})

f_read_lookahead_index(s::JS.ParseStream) = Int64(s.lookahead_index)
try_compile("read_lookahead_index", f_read_lookahead_index, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 2: peek(s) with default k=1
# ============================================================================
println("\n=== LEVEL 2: peek(s) with default k=1 ===")

# First, check what peek actually does (host-side)
ps_test = JS.ParseStream("1 + 2")
println("  [INFO] Host peek(s) returns: ", JS.peek(ps_test))
println("  [INFO] Host peek(s, 1) returns: ", JS.peek(ps_test, 1))
println("  [INFO] Host peek(s, 2) returns: ", JS.peek(ps_test, 2))

# Test peek with default argument
f_peek_default(s::JS.ParseStream) = begin
    tok = JS.peek(s)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("peek_default_k1", f_peek_default, Tuple{JS.ParseStream})

# Test peek with explicit k=1
f_peek_1(s::JS.ParseStream) = begin
    tok = JS.peek(s, 1)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("peek_explicit_k1", f_peek_1, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 3: peek(s, 2) - the known crash site
# ============================================================================
println("\n=== LEVEL 3: peek(s, 2) - known crash site ===")

f_peek_2(s::JS.ParseStream) = begin
    tok = JS.peek(s, 2)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("peek_explicit_k2", f_peek_2, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 4: peek_token directly
# ============================================================================
println("\n=== LEVEL 4: peek_token directly ===")

f_peek_token_1(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 1)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("peek_token_k1", f_peek_token_1, Tuple{JS.ParseStream})

f_peek_token_2(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 2)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("peek_token_k2", f_peek_token_2, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 5: _buffer_lookahead_tokens
# ============================================================================
println("\n=== LEVEL 5: _buffer_lookahead_tokens ===")

f_buffer_tokens(s::JS.ParseStream) = begin
    lexer = s.lexer
    lookahead = s.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)
    return Int64(length(lookahead))
end
try_compile("buffer_lookahead_tokens", f_buffer_tokens, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 6: next_token
# ============================================================================
println("\n=== LEVEL 6: next_token ===")

f_next_token(s::JS.ParseStream) = begin
    tok = JS.next_token(s.lexer)
    return Int64(reinterpret(UInt32, tok.head))
end
try_compile("next_token", f_next_token, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 7: Combined operations
# ============================================================================
println("\n=== LEVEL 7: Combined operations ===")

f_peek_then_bump(s::JS.ParseStream) = begin
    tok1 = JS.peek(s)
    JS.bump(s)
    tok2 = JS.peek(s)
    return (Int64(reinterpret(UInt32, tok1.head)), Int64(reinterpret(UInt32, tok2.head)))
end
try_compile("peek_then_bump", f_peek_then_bump, Tuple{JS.ParseStream})

# ============================================================================
# LEVEL 8: Examine IR code for peek variants
# ============================================================================
println("\n=== LEVEL 8: IR code examination ===")

function examine_ir(name, f, argT)
    print("  $name ... ")
    flush(stdout)
    try
        # Get the IR code without compiling
        sig = Tuple{typeof(f), argT.parameters...}
        mi = ccall(:jl_method_lookup, Any, (Any, Any, UInt), f, argT.parameters, length(argT.parameters))
        if mi !== nothing
            println("✅ Got MethodInstance")
        else
            println("❌ No MethodInstance found")
        end
    catch e
        println("❌ Error: ", typeof(e).name)
    end
end

examine_ir("peek_default_IR", f_peek_default, Tuple{JS.ParseStream})
examine_ir("peek_k2_IR", f_peek_2, Tuple{JS.ParseStream})

println("\n" * "=" ^ 70)
println("PROBE COMPLETE — All compilation attempts recorded above")
println("=" ^ 70)
