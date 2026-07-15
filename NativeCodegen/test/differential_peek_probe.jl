# differential_peek_probe.jl — Escalating differential probes to find FIRST native-vs-host divergence
#
# Bug: peek(s,1) works but peek(s,2) SIGSEGVs. Crash in __compiled_fn_..._peek_token.
# Strategy: escalate from simplest to more complex operations, comparing native vs host at each step.

using NativeCodegen
using Libdl
import Base.JuliaSyntax as JS

k2i(k) = Int64(reinterpret(UInt16, k))

function try_native(name, f, retT, argT, args...; verbose=true, flush_before=true)
    verbose && print("  $name ... ")
    flush(stdout)

    # Host result
    host = try
        flush(stdout)
        f(args...)
    catch e
        sprint(showerror, e)
    end

    # Native result
    native = try
        flush(stdout)
        comp = compile_native(f, argT; name=name)
        nf = native_callable_from_so(comp, retT, argT.parameters...)
        flush(stdout)
        r = nf(args...)
        flush(stdout)
        rm(comp.so_path)
        r
    catch e
        if e isa InterruptException; rethrow(); end
        sprint(showerror, e)
    end

    ok = (host == native) && !(host isa AbstractString)
    verbose && println(ok ? "✅ host=$host native=$native" :
                            "❌ host=$host native=$native")
    return ok, host, native
end

println("=" ^ 70)
println("DIFFERENTIAL PEEK PROBE — Finding first native-vs-host divergence")
println("=" ^ 70)

# ============================================================================
# LEVEL 1: Basic peek operations on "1 + 2"
# ============================================================================
println("\n=== LEVEL 1: peek(s, k) on \"1 + 2\" ===")

println("\n--- Test 1.1: peek(s) default (k=1) [known pass] ---")
f_peek1(s::JS.ParseStream) = k2i(JS.peek(s))
ps1 = JS.ParseStream("1 + 2")
ok1_1, h1_1, n1_1 = try_native("peek_1_default", f_peek1, Int64, Tuple{JS.ParseStream}, ps1)

println("\n--- Test 1.2: peek(s, 2) [known SIGSEGV] ---")
f_peek2(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps2 = JS.ParseStream("1 + 2")
ok1_2, h1_2, n1_2 = try_native("peek_2_on_1plus2", f_peek2, Int64, Tuple{JS.ParseStream}, ps2)

println("\n--- Test 1.3: peek(s, 3) ---")
f_peek3(s::JS.ParseStream) = k2i(JS.peek(s, 3))
ps3 = JS.ParseStream("1 + 2")
ok1_3, h1_3, n1_3 = try_native("peek_3_on_1plus2", f_peek3, Int64, Tuple{JS.ParseStream}, ps3)

# ============================================================================
# LEVEL 2: Stream state after peek(s, 2)
# ============================================================================
println("\n=== LEVEL 2: Stream state after peek(s, 2) ===")

println("\n--- Test 2.1: lookahead_index after peek(s, 2) ---")
f_peek2_li(s::JS.ParseStream) = begin
    JS.peek(s, 2)
    return Int64(s.lookahead_index)
end
ps2_li = JS.ParseStream("1 + 2")
ok2_1, h2_1, n2_1 = try_native("peek2_lookahead_index", f_peek2_li, Int64, Tuple{JS.ParseStream}, ps2_li)

println("\n--- Test 2.2: length(stream.lookahead) after peek(s, 2) ---")
f_peek2_ll(s::JS.ParseStream) = begin
    JS.peek(s, 2)
    return Int64(length(s.lookahead))
end
ps2_ll = JS.ParseStream("1 + 2")
ok2_2, h2_2, n2_2 = try_native("peek2_lookahead_len", f_peek2_ll, Int64, Tuple{JS.ParseStream}, ps2_ll)

println("\n--- Test 2.3: next_byte after peek(s, 2) ---")
f_peek2_nb(s::JS.ParseStream) = begin
    JS.peek(s, 2)
    return Int64(s.next_byte)
end
ps2_nb = JS.ParseStream("1 + 2")
ok2_3, h2_3, n2_3 = try_native("peek2_next_byte", f_peek2_nb, Int64, Tuple{JS.ParseStream}, ps2_nb)

println("\n--- Test 2.4: Full state tuple after peek(s, 2) ---")
f_peek2_state(s::JS.ParseStream) = begin
    li_before = Int64(s.lookahead_index)
    ll_before = Int64(length(s.lookahead))
    nb_before = Int64(s.next_byte)

    JS.peek(s, 2)

    li_after = Int64(s.lookahead_index)
    ll_after = Int64(length(s.lookahead))
    nb_after = Int64(s.next_byte)

    return (li_before, ll_before, nb_before, li_after, ll_after, nb_after)
end
ps2_state = JS.ParseStream("1 + 2")
ok2_4, h2_4, n2_4 = try_native("peek2_full_state", f_peek2_state, Tuple{Int64,Int64,Int64,Int64,Int64,Int64}, Tuple{JS.ParseStream}, ps2_state)

# ============================================================================
# LEVEL 3: peek(s, 2) on simpler inputs
# ============================================================================
println("\n=== LEVEL 3: peek(s, 2) on simpler inputs ===")

println("\n--- Test 3.1: peek(s, 2) on \"12\" ---")
f_peek2_12(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps_12 = JS.ParseStream("12")
ok3_1, h3_1, n3_1 = try_native("peek2_on_12", f_peek2_12, Int64, Tuple{JS.ParseStream}, ps_12)

println("\n--- Test 3.2: peek(s, 2) on \"1\" ---")
f_peek2_1(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps_1 = JS.ParseStream("1")
ok3_2, h3_2, n3_2 = try_native("peek2_on_1", f_peek2_1, Int64, Tuple{JS.ParseStream}, ps_1)

println("\n--- Test 3.3: peek(s, 2) on \"ab\" ---")
f_peek2_ab(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps_ab = JS.ParseStream("ab")
ok3_3, h3_3, n3_3 = try_native("peek2_on_ab", f_peek2_ab, Int64, Tuple{JS.ParseStream}, ps_ab)

println("\n--- Test 3.4: peek(s, 2) on \"a \" ---")
f_peek2_as(s::JS.ParseStream) = k2i(JS.peek(s, 2))
ps_as = JS.ParseStream("a ")
ok3_4, h3_4, n3_4 = try_native("peek2_on_a_space", f_peek2_as, Int64, Tuple{JS.ParseStream}, ps_as)

# ============================================================================
# LEVEL 4: Direct _buffer_lookahead_tokens calls
# ============================================================================
println("\n=== LEVEL 4: Direct _buffer_lookahead_tokens calls ===")

println("\n--- Test 4.1: _buffer_lookahead_tokens once on fresh stream ---")
f_buffer_once(s::JS.ParseStream) = begin
    lexer = s.lexer
    lookahead = s.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 1)  # Buffer 1 token
    return Int64(length(lookahead))
end
ps_buf1 = JS.ParseStream("1 + 2")
ok4_1, h4_1, n4_1 = try_native("buffer_1_token", f_buffer_once, Int64, Tuple{JS.ParseStream}, ps_buf1)

println("\n--- Test 4.2: _buffer_lookahead_tokens twice (buffer 2 tokens) ---")
f_buffer_twice(s::JS.ParseStream) = begin
    lexer = s.lexer
    lookahead = s.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 1)
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)
    return Int64(length(lookahead))
end
ps_buf2 = JS.ParseStream("1 + 2")
ok4_2, h4_2, n4_2 = try_native("buffer_2_tokens", f_buffer_twice, Int64, Tuple{JS.ParseStream}, ps_buf2)

println("\n--- Test 4.3: _buffer_lookahead_tokens then read lookahead[2] ---")
f_buffer_and_read(s::JS.ParseStream) = begin
    lexer = s.lexer
    lookahead = s.lookahead
    JS._buffer_lookahead_tokens(lexer, lookahead, 2)
    tok = lookahead[2]
    return k2i(tok.kind)
end
ps_buf_read = JS.ParseStream("1 + 2")
ok4_3, h4_3, n4_3 = try_native("buffer_and_read_idx2", f_buffer_and_read, Int64, Tuple{JS.ParseStream}, ps_buf_read)

# ============================================================================
# LEVEL 5: next_token at different positions
# ============================================================================
println("\n=== LEVEL 5: next_token at different positions ===")

println("\n--- Test 5.1: next_token at byte 0 on \"1 + 2\" ---")
f_next_token0(s::JS.ParseStream) = begin
    lexer = s.lexer
    tok = JS.next_token(lexer)
    return k2i(tok.kind)
end
ps_nt0 = JS.ParseStream("1 + 2")
ok5_1, h5_1, n5_1 = try_native("next_token_byte0", f_next_token0, Int64, Tuple{JS.ParseStream}, ps_nt0)

println("\n--- Test 5.2: next_token after bump to byte 1 ---")
f_next_token1(s::JS.ParseStream) = begin
    lexer = s.lexer
    # First token consumes 1 byte ("1")
    tok1 = JS.next_token(lexer)
    # Now at byte 1 (space)
    tok2 = JS.next_token(lexer)
    return (k2i(tok1.kind), k2i(tok2.kind))
end
ps_nt1 = JS.ParseStream("1 + 2")
ok5_2, h5_2, n5_2 = try_native("next_token_byte1", f_next_token1, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps_nt1)

println("\n--- Test 5.3: Three consecutive next_token calls ---")
f_next_token3(s::JS.ParseStream) = begin
    lexer = s.lexer
    tok1 = JS.next_token(lexer)
    tok2 = JS.next_token(lexer)
    tok3 = JS.next_token(lexer)
    return (k2i(tok1.kind), k2i(tok2.kind), k2i(tok3.kind))
end
ps_nt3 = JS.ParseStream("1 + 2")
ok5_3, h5_3, n5_3 = try_native("next_token_3x", f_next_token3, Tuple{Int64,Int64,Int64}, Tuple{JS.ParseStream}, ps_nt3)

# ============================================================================
# LEVEL 6: peek_token internals (the crash site)
# ============================================================================
println("\n=== LEVEL 6: peek_token internals ===")

println("\n--- Test 6.1: peek_token(s, 1) directly ---")
f_peek_token1(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 1)
    return k2i(tok.kind)
end
ps_pt1 = JS.ParseStream("1 + 2")
ok6_1, h6_1, n6_1 = try_native("peek_token_1", f_peek_token1, Int64, Tuple{JS.ParseStream}, ps_pt1)

println("\n--- Test 6.2: peek_token(s, 2) directly [CRASH SITE] ---")
f_peek_token2(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 2)
    return k2i(tok.kind)
end
ps_pt2 = JS.ParseStream("1 + 2")
ok6_2, h6_2, n6_2 = try_native("peek_token_2", f_peek_token2, Int64, Tuple{JS.ParseStream}, ps_pt2; flush_before=true)

# ============================================================================
# SUMMARY
# ============================================================================
println("\n" * "=" ^ 70)
println("SUMMARY OF FIRST DIVERGENCE")
println("=" ^ 70)

results = [
    ("LEVEL 1.1: peek(s,1)", ok1_1, h1_1, n1_1),
    ("LEVEL 1.2: peek(s,2)", ok1_2, h1_2, n1_2),
    ("LEVEL 1.3: peek(s,3)", ok1_3, h1_3, n1_3),
    ("LEVEL 2.1: peek2 lookahead_index", ok2_1, h2_1, n2_1),
    ("LEVEL 2.2: peek2 lookahead_len", ok2_2, h2_2, n2_2),
    ("LEVEL 2.3: peek2 next_byte", ok2_3, h2_3, n2_3),
    ("LEVEL 3.1: peek2 on \"12\"", ok3_1, h3_1, n3_1),
    ("LEVEL 3.2: peek2 on \"1\"", ok3_2, h3_2, n3_2),
    ("LEVEL 3.3: peek2 on \"ab\"", ok3_3, h3_3, n3_3),
    ("LEVEL 3.4: peek2 on \"a \"", ok3_4, h3_4, n3_4),
    ("LEVEL 4.1: buffer 1 token", ok4_1, h4_1, n4_1),
    ("LEVEL 4.2: buffer 2 tokens", ok4_2, h4_2, n4_2),
    ("LEVEL 4.3: buffer + read idx2", ok4_3, h4_3, n4_3),
    ("LEVEL 5.1: next_token byte0", ok5_1, h5_1, n5_1),
    ("LEVEL 5.2: next_token byte1", ok5_2, h5_2, n5_2),
    ("LEVEL 5.3: next_token 3x", ok5_3, h5_3, n5_3),
    ("LEVEL 6.1: peek_token(s,1)", ok6_1, h6_1, n6_1),
    ("LEVEL 6.2: peek_token(s,2)", ok6_2, h6_2, n6_2),
]

first_failure = nothing
for (name, ok, h, n) in results
    status = ok ? "✅" : "❌"
    println("$status $name (host=$h, native=$n)")
    if !ok && first_failure === nothing
        first_failure = (name, h, n)
    end
end

println("\n" * "=" ^ 70)
if first_failure !== nothing
    name, h, n = first_failure
    println("🎯 FIRST DIVERGENCE: $name")
    println("   Host value: $h")
    println("   Native value: $n")
else
    println("🎉 ALL TESTS PASSED — No divergence found in these probes")
end
println("=" ^ 70)
