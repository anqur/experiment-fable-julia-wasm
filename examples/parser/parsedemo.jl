# The full-JuliaSyntax-parser-to-wasm stress test.
#
# `parse_into(src)` runs the complete recursive-descent parser
# (JuliaSyntax.parse! over a ParseStream) inside wasm and streams out the
# parser's native output representation:
#   emit_token(kind | flags<<16, orig_kind | ws<<16, next_byte)
#   emit_node(kind | flags<<16, first_token, last_token)
# The green tree is a pure host-side reconstruction of these events
# (exactly what JuliaSyntax.build_tree does). Returns ntokens + nranges.

using JuliaSyntax
using WasmCodegen: WASM_MT, _hb_reset, _hb_push, _hb_parse_f64, _hb_parse_f32,
                   _hb_status

# Float literal parsing: digit normalization runs in wasm; the strtod happens
# on the host via WasmCodegen's byte bridge. Mirrors parse_float_literal's
# contract: (value, :ok | :underflow | :overflow). The 'f' exponent marker of
# Float32 literals becomes 'e' (decimal literals only — Float32 has no
# hexfloat form, so 'f' is unambiguous).
Base.Experimental.@overlay WASM_MT function JuliaSyntax.parse_float_literal(
        ::Type{T}, str::Vector{UInt8},
        firstind::Integer, endind::Integer) where {T}
    _hb_reset()
    i = Int(firstind)
    while i < endind
        b = str[i]
        if b == UInt8('_')
            i += 1
            continue
        elseif b == 0xe2 && i + 2 < endind && str[i+1] == 0x88 && str[i+2] == 0x92
            b = UInt8('-')   # unicode minus sign
            i += 2
        elseif b == UInt8('f') && T === Float32
            b = UInt8('e')
        end
        _hb_push(b)
        i += 1
    end
    x = T === Float64 ? _hb_parse_f64() : _hb_parse_f32()
    st = _hb_status()
    return (x, st == Int32(0) ? :ok : st == Int32(1) ? :underflow : :overflow)
end

const TOKEN_SINK = Ref{Vector{NTuple{3,Int64}}}(NTuple{3,Int64}[])
const NODE_SINK = Ref{Vector{NTuple{3,Int64}}}(NTuple{3,Int64}[])

# NOT const: pins the emitters to the host (see lexer demo)
SINK_GUARD::Bool = true

@noinline function emit_token(a::Int64, b::Int64, c::Int64)
    SINK_GUARD || return nothing
    push!(TOKEN_SINK[], (a, b, c))
    return nothing
end

@noinline function emit_node(a::Int64, b::Int64, c::Int64)
    SINK_GUARD || return nothing
    push!(NODE_SINK[], (a, b, c))
    return nothing
end

_head_bits(h::JuliaSyntax.SyntaxHead) =
    Int64(reinterpret(UInt16, JuliaSyntax.kind(h))) |
    (Int64(JuliaSyntax.flags(h)) << 16)

function parse_into(src::String)
    ps = JuliaSyntax.ParseStream(src)
    JuliaSyntax.parse!(ps; rule=:all)
    for t in ps.tokens
        emit_token(_head_bits(t.head),
                   Int64(reinterpret(UInt16, t.orig_kind)) |
                       (Int64(t.preceding_whitespace) << 16),
                   Int64(t.next_byte))
    end
    for r in ps.ranges
        emit_node(_head_bits(r.head), Int64(r.first_token), Int64(r.last_token))
    end
    return length(ps.tokens) * 1000000 + length(ps.ranges)
end

function native_events(src::String)
    ps = JuliaSyntax.ParseStream(src)
    JuliaSyntax.parse!(ps; rule=:all)
    toks = [(_head_bits(t.head),
             Int64(reinterpret(UInt16, t.orig_kind)) |
                 (Int64(t.preceding_whitespace) << 16),
             Int64(t.next_byte)) for t in ps.tokens]
    rngs = [(_head_bits(r.head), Int64(r.first_token), Int64(r.last_token))
            for r in ps.ranges]
    return toks, rngs
end
