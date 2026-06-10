# The JuliaSyntax-lexer-to-wasm stress test.
#
# `lex_into(src)` runs the raw JuliaSyntax lexer (JuliaSyntax.Tokenize) and
# reports each token through `emit_token`, a host import carrying
# (kind, startbyte, endbyte) as Int64s (byte offsets are 0-based, endbyte
# inclusive). The host — the Julia differential harness, or JavaScript in the
# browser — collects the triples. Returns the token count.

using JuliaSyntax

const TOKEN_SINK = Ref{Vector{NTuple{3,Int64}}}(NTuple{3,Int64}[])

# NOT const: reading a non-const global is uncompilable, which pins this
# function to the host (a materialized copy of the sink would otherwise
# swallow the tokens wasm-side).
TOKEN_GUARD::Bool = true

@noinline function emit_token(kind::Int64, a::Int64, b::Int64)
    TOKEN_GUARD || return nothing
    push!(TOKEN_SINK[], (kind, a, b))
    return nothing
end

function lex_into(src::String)
    n = 0
    for t in JuliaSyntax.Tokenize.tokenize(src)
        emit_token(Int64(reinterpret(UInt16, t.kind)),
                   Int64(t.startbyte), Int64(t.endbyte))
        n += 1
    end
    return n
end

native_tokens(src::String) =
    [(Int64(reinterpret(UInt16, t.kind)), Int64(t.startbyte), Int64(t.endbyte))
     for t in JuliaSyntax.Tokenize.tokenize(src)]
