# test_peek_token_host.jl - Check what peek_token does on host (no native compilation)

import Base.JuliaSyntax as JS

println("=== Host execution trace of peek_token ===")

ps = JS.ParseStream("1 + 2")

println("\nInitial state:")
println("  lookahead_index: ", ps.lookahead_index)
println("  length(lookahead): ", length(ps.lookahead))
println("  next_byte: ", ps.next_byte)

println("\nCalling JS.peek_token(ps)...")
tok = JS.peek_token(ps)

println("\nAfter peek_token:")
println("  lookahead_index: ", ps.lookahead_index)
println("  length(lookahead): ", length(ps.lookahead))
println("  next_byte: ", ps.next_byte)
println("  token.head: ", tok.head)
println("  token.orig_kind: ", tok.orig_kind)

println("\nNow calling JS.peek_token(ps, 2)...")
tok2 = JS.peek_token(ps, 2)

println("\nAfter peek_token(ps, 2):")
println("  lookahead_index: ", ps.lookahead_index)
println("  length(lookahead): ", length(ps.lookahead))
println("  next_byte: ", ps.next_byte)
println("  token.head: ", tok2.head)
println("  token.orig_kind: ", tok2.orig_kind)
