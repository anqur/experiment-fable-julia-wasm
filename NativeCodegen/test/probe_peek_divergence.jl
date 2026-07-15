# probe_peek_divergence.jl — Escalating differential probes to find FIRST native-vs-host divergence
#
# Bug: peek(s,1) works but peek(s,2) SIGSEGVs. Crash in __compiled_fn_..._peek_token.
# Suspect: buffering loop / lookahead read miscompiles for k>=2.
#
# Strategy: escalate from simple to complex, capturing output BEFORE any crash.
# Use println+flush before native calls; wrap in try/catch.

using NativeCodegen
using Libdl
import Base.JuliaSyntax as JS

k2i(k) = Int64(reinterpret(UInt16, k))

function try_native_safe(name, f, retT, argT, args...; verbose=true)
    """Run f natively with safe capture; return (success, host, native, error_msg)"""
    verbose && print("  $name ... ")

    # Host execution
    host = try
        f(args...)
    catch e
        sprint(showerror, e)
    end

    # Native execution with crash protection
    native = nothing
    error_msg = ""
    success = false

    try
        # Flush before native call
        flush(stdout)

        comp = compile_native(f, argT; name=name)
        nf = native_callable_from_so(comp, retT, argT.parameters...)
        native = nf(args...)
        rm(comp.so_path)

        success = (host == native) && !(host isa AbstractString)
    catch e
        if e isa InterruptException
            rethrow()
        end
        error_msg = sprint(showerror, e)
        native = error_msg
        success = false
    end

    if verbose
        if success
            println("✅ host=$host native=$native")
        elseif !isempty(error_msg)
            println("❌ CRASH: $error_msg")
        else
            println("❌ host=$host native=$native")
        end
    end

    return success, host, native, error_msg
end

println("\n" * "="^70)
println("ESCALATING PROBE BATTERY: peek(s, k) divergence")
println("="^70)

println("\n### LEVEL 1: Basic peek escalation on \"1 + 2\" ###")

# Test 1.0: peek(s) with NO argument (baseline - should work)
println("\n1.0: peek(s) NO ARG on \"1 + 2\"")
f_peek0(s::JS.ParseStream) = k2i(JS.peek(s))
ps0 = JS.ParseStream("1 + 2")
ok0, h0, n0, err0 = try_native_safe("peek0", f_peek0, Int64, Tuple{JS.ParseStream}, ps0)

# Test 1.1: peek(s, 1) - EXPLICIT k=1 (may differ from peek(s))
println("\n1.1: peek(s, 1) EXPLICIT on \"1 + 2\"")
f_peek1(s::JS.ParseStream) = k2i(JS.peek(s, 1))
ps1 = JS.ParseStream("1 + 2")
ok1, h1, n1, err1 = try_native_safe("peek1", f_peek1, Int64, Tuple{JS.ParseStream}, ps1)

# Test 1.2: peek(s, 2) - KNOWN TO CRASH
println("\n1.2: peek(s, 2) on \"1 + 2\"")
f_peek2(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps2 = JS.ParseStream("1 + 2")
flush(stdout)
ok2, h2, n2, err2 = try_native_safe("peek2", f_peek2, Int64, Tuple{JS.ParseStream}, ps2)

# Test 1.3: peek(s, 3) - check if pattern continues
println("\n1.3: peek(s, 3) on \"1 + 2\"")
f_peek3(s::JS.ParseStream) = k2i(JS.peek(s, 3))
ps3 = JS.ParseStream("1 + 2")
flush(stdout)
ok3, h3, n3, err3 = try_native_safe("peek3", f_peek3, Int64, Tuple{JS.ParseStream}, ps3)

println("\n### LEVEL 2: Stream state inspection after peek(s, 2) ###")

# Test 2.1: Check lookahead_index after peek(s, 2)
println("\n2.1: lookahead_index after peek(s, 2)")
f_la_idx(s::JS.ParseStream) = begin
    result = JS.peek(s, 2)
    li = Int64(s.lookahead_index)
    return (k2i(result), li)
end
ps4 = JS.ParseStream("1 + 2")
flush(stdout)
ok4, h4, n4, err4 = try_native_safe("peek2_la_idx", f_la_idx, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps4)

# Test 2.2: Check length(stream.lookahead) after peek(s, 2)
println("\n2.2: length(stream.lookahead) after peek(s, 2)")
f_la_len(s::JS.ParseStream) = begin
    result = JS.peek(s, 2)
    llen = Int64(length(s.lookahead))
    return (k2i(result), llen)
end
ps5 = JS.ParseStream("1 + 2")
flush(stdout)
ok5, h5, n5, err5 = try_native_safe("peek2_la_len", f_la_len, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps5)

# Test 2.3: Check next_byte after peek(s, 2)
println("\n2.3: next_byte after peek(s, 2)")
f_nb_after(s::JS.ParseStream) = begin
    result = JS.peek(s, 2)
    nb = Int64(s.next_byte)
    return (k2i(result), nb)
end
ps6 = JS.ParseStream("1 + 2")
flush(stdout)
ok6, h6, n6, err6 = try_native_safe("peek2_nb", f_nb_after, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps6)

# Test 2.4: Full state dump after peek(s, 2)
println("\n2.4: Full stream state after peek(s, 2)")
f_full_state(s::JS.ParseStream) = begin
    result = JS.peek(s, 2)
    li = Int64(s.lookahead_index)
    llen = Int64(length(s.lookahead))
    nb = Int64(s.next_byte)
    return (k2i(result), li, llen, nb)
end
ps7 = JS.ParseStream("1 + 2")
flush(stdout)
ok7, h7, n7, err7 = try_native_safe("peek2_full_state", f_full_state, Tuple{Int64,Int64,Int64,Int64}, Tuple{JS.ParseStream}, ps7)

println("\n### LEVEL 3: Simpler inputs to isolate buffering behavior ###")

# Test 3.1: peek(s, 2) on "12" (two digits)
println("\n3.1: peek(s, 2) on \"12\"")
f_peek2_12(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps8 = JS.ParseStream("12")
flush(stdout)
ok8, h8, n8, err8 = try_native_safe("peek2_12", f_peek2_12, Int64, Tuple{JS.ParseStream}, ps8)

# Test 3.2: peek(s, 2) on "1" (too short)
println("\n3.2: peek(s, 2) on \"1\" (too short)")
f_peek2_1(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps9 = JS.ParseStream("1")
flush(stdout)
ok9, h9, n9, err9 = try_native_safe("peek2_1", f_peek2_1, Int64, Tuple{JS.ParseStream}, ps9)

# Test 3.3: peek(s, 2) on "ab" (two letters)
println("\n3.3: peek(s, 2) on \"ab\"")
f_peek2_ab(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps10 = JS.ParseStream("ab")
flush(stdout)
ok10, h10, n10, err10 = try_native_safe("peek2_ab", f_peek2_ab, Int64, Tuple{JS.ParseStream}, ps10)

# Test 3.4: peek(s, 2) on "a " (letter + space)
println("\n3.4: peek(s, 2) on \"a \"")
f_peek2_a_sp(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps11 = JS.ParseStream("a ")
flush(stdout)
ok11, h11, n11, err11 = try_native_safe("peek2_a_sp", f_peek2_a_sp, Int64, Tuple{JS.ParseStream}, ps11)

println("\n### LEVEL 4: Direct _buffer_lookahead_tokens test ###")

# Test 4.1: Call _buffer_lookahead_tokens once on fresh stream
println("\n4.1: _buffer_lookahead_tokens(lexer, lookahead) once")
f_buffer_once(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    lookahead = ps.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)  # Buffer 2 tokens
    return Int64(length(lookahead))
end
ok12, h12, n12, err12 = try_native_safe("buffer_once_2", f_buffer_once, Int64, Tuple{String}, "1 + 2")

# Test 4.2: Buffer tokens on simpler input
println("\n4.2: _buffer_lookahead_tokens on \"12\"")
f_buffer_12(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    lookahead = ps.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)
    return Int64(length(lookahead))
end
ok13, h13, n13, err13 = try_native_safe("buffer_12", f_buffer_12, Int64, Tuple{String}, "12")

println("\n### LEVEL 5: next_token at different positions ###")

# Test 5.1: next_token at byte 0 (first token)
println("\n5.1: next_token at position 0")
f_next_token_0(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    tok = JS.next_token(lexer)
    return k2i(tok.kind)
end
ok14, h14, n14, err14 = try_native_safe("next_token_0", f_next_token_0, Int64, Tuple{String}, "1 + 2")

# Test 5.2: Two consecutive next_token calls
println("\n5.2: Two consecutive next_token calls")
f_next_token_2(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    tok1 = JS.next_token(lexer)
    tok2 = JS.next_token(lexer)
    return (k2i(tok1.kind), k2i(tok2.kind))
end
ok15, h15, n15, err15 = try_native_safe("next_token_2", f_next_token_2, Tuple{Int64,Int64}, Tuple{String}, "1 + 2")

# Test 5.3: next_token, check lexer state (next_byte)
println("\n5.3: next_token advances lexer.next_byte")
f_next_token_advances(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    nb0 = Int64(lexer.next_byte)
    tok1 = JS.next_token(lexer)
    nb1 = Int64(lexer.next_byte)
    tok2 = JS.next_token(lexer)
    nb2 = Int64(lexer.next_byte)
    return (nb0, nb1, nb2, k2i(tok1.kind), k2i(tok2.kind))
end
ok16, h16, n16, err16 = try_native_safe("next_token_advances", f_next_token_advances, Tuple{Int64,Int64,Int64,Int64,Int64}, Tuple{String}, "12")

println("\n### LEVEL 6: peek_token internals ###")

# Test 6.1: Read lookahead[k] directly after buffering
println("\n6.1: Read lookahead[2] after manual buffering")
f_read_la2(src::String) = begin
    ps = JS.ParseStream(src)
    lexer = ps.lexer
    lookahead = ps.lookahead

    # Manually buffer 2 tokens
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)

    # Read the 2nd token (1-indexed)
    tok = lookahead[2]
    return k2i(tok.kind)
end
ok17, h17, n17, err17 = try_native_safe("read_la2", f_read_la2, Int64, Tuple{String}, "1 + 2")

# Test 6.2: Check lookahead_index arithmetic
println("\n6.2: lookahead_index + k - 1 arithmetic")
f_la_index_arith(s::JS.ParseStream) = begin
    # Buffer some tokens first
    JS.peek(s, 2)
    li = Int64(s.lookahead_index)
    # Compute index for k=2: lookahead_index + 2 - 1
    idx = li + 2 - 1
    return idx
end
ps12 = JS.ParseStream("1 + 2")
flush(stdout)
ok18, h18, n18, err18 = try_native_safe("la_index_arith", f_la_index_arith, Int64, Tuple{JS.ParseStream}, ps12)

println("\n### SUMMARY OF DIVERGENCES ###")
println("="^70)
println("Level 1 (peek escalation):")
println("  peek(s) NO ARG: $(ok0 ? "✅" : "❌") $(ok0 ? "" : "- $err0")")
println("  peek(s,1) EXPLICIT: $(ok1 ? "✅" : "❌") $(ok1 ? "" : "- $err1")")
println("  peek(s,2):   $(ok2 ? "✅" : "❌") $(ok2 ? "" : "- $err2")")
println("  peek3:   $(ok3 ? "✅" : "❌") $(ok3 ? "" : "- $err3")")
println("\nLevel 2 (state after peek2):")
println("  la_idx:  $(ok4 ? "✅" : "❌") $(ok4 ? "" : "- $err4")")
println("  la_len:  $(ok5 ? "✅" : "❌") $(ok5 ? "" : "- $err5")")
println("  next_b:  $(ok6 ? "✅" : "❌") $(ok6 ? "" : "- $err6")")
println("  full:    $(ok7 ? "✅" : "❌") $(ok7 ? "" : "- $err7")")
println("\nLevel 3 (simpler inputs):")
println("  \"12\":    $(ok8 ? "✅" : "❌") $(ok8 ? "" : "- $err8")")
println("  \"1\":     $(ok9 ? "✅" : "❌") $(ok9 ? "" : "- $err9")")
println("  \"ab\":    $(ok10 ? "✅" : "❌") $(ok10 ? "" : "- $err10")")
println("  \"a \":    $(ok11 ? "✅" : "❌") $(ok11 ? "" : "- $err11")")
println("\nLevel 4 (buffer_lookahead):")
println("  \"1+2\":   $(ok12 ? "✅" : "❌") $(ok12 ? "" : "- $err12")")
println("  \"12\":    $(ok13 ? "✅" : "❌") $(ok13 ? "" : "- $err13")")
println("\nLevel 5 (next_token):")
println("  pos 0:   $(ok14 ? "✅" : "❌") $(ok14 ? "" : "- $err14")")
println("  2 calls: $(ok15 ? "✅" : "❌") $(ok15 ? "" : "- $err15")")
println("  advance: $(ok16 ? "✅" : "❌") $(ok16 ? "" : "- $err16")")
println("\nLevel 6 (peek_token internals):")
println("  read[2]: $(ok17 ? "✅" : "❌") $(ok17 ? "" : "- $err17")")
println("  arith:   $(ok18 ? "✅" : "❌") $(ok18 ? "" : "- $err18")")
println("="^70)

# Find first failure
first_fail = nothing
if !ok0; first_fail = "peek(s) NO ARG on \"1 + 2\""; end
if !ok1 && first_fail === nothing; first_fail = "peek(s, 1) EXPLICIT on \"1 + 2\""; end
if !ok2 && first_fail === nothing; first_fail = "peek(s, 2) on \"1 + 2\""; end
if !ok4 && first_fail === nothing; first_fail = "peek2 lookahead_index"; end
if !ok5 && first_fail === nothing; first_fail = "peek2 lookahead length"; end
if !ok6 && first_fail === nothing; first_fail = "peek2 next_byte"; end
if !ok8 && first_fail === nothing; first_fail = "peek2 on \"12\""; end
if !ok12 && first_fail === nothing; first_fail = "_buffer_lookahead_tokens on \"1+2\""; end
if !ok14 && first_fail === nothing; first_fail = "next_token at pos 0"; end
if !ok15 && first_fail === nothing; first_fail = "Two next_token calls"; end
if !ok17 && first_fail === nothing; first_fail = "Read lookahead[2] after buffer"; end

if first_fail !== nothing
    println("\n🔍 FIRST DIVERGENCE: $first_fail")
else
    println("\n✅ All probes passed - bug not captured by this test suite")
end
