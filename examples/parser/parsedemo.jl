# The full-JuliaSyntax-parser-to-wasm stress test.
#
# `parse_into(src, vminor)` runs the complete recursive-descent parser
# (JuliaSyntax.parse! over a ParseStream) inside wasm and streams out the
# parser's native output representation — the post-order RawGreenNode array:
#   emit_node(kind | flags<<16, byte_span, node_span_or_orig_kind)
# (flags bit 7 = non-terminal; for terminals the third value is orig_kind).
# The green tree is a pure host-side reconstruction of these events, exactly
# mirroring JuliaSyntax's GreenTreeCursor. Returns the number of events.

# Compile the LATEST parser: the JuliaSyntax vendored into Base (it moved
# in-tree), which carries the new 1.14 syntax gates (typegroup, labeled
# break/continue, module VERSION markers) ahead of the standalone releases.
const JuliaSyntax = Base.JuliaSyntax
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

const NODE_SINK = Ref{Vector{NTuple{3,Int64}}}(NTuple{3,Int64}[])

# NOT const: pins the emitter to the host (see lexer demo)
SINK_GUARD::Bool = true

@noinline function emit_node(a::Int64, b::Int64, c::Int64)
    SINK_GUARD || return nothing
    push!(NODE_SINK[], (a, b, c))
    return nothing
end

_head_bits(h::JuliaSyntax.SyntaxHead) =
    Int64(reinterpret(UInt16, JuliaSyntax.kind(h))) |
    (Int64(JuliaSyntax.flags(h)) << 16)

_node_event(n::JuliaSyntax.RawGreenNode) =
    (_head_bits(getfield(n, :head)),
     Int64(getfield(n, :byte_span)),
     Int64(getfield(n, :node_span_or_orig_kind)))

# `vminor` selects the Julia syntax version v1.<vminor> (JuliaSyntax gates
# parsing differences at 1.6/1.7/1.8/1.11/1.12/1.14)
function parse_into(src::String, vminor::Int64)
    ps = JuliaSyntax.ParseStream(src; version=VersionNumber(1, Int(vminor), 0))
    JuliaSyntax.parse!(ps; rule=:all)
    out = ps.output
    i = 2                          # output[1] is the cursor sentinel
    while i <= length(out)
        ev = _node_event(@inbounds out[i])
        emit_node(ev[1], ev[2], ev[3])
        i += 1
    end
    return Int64(length(out) - 1)
end

function native_events(src::String, vminor::Integer=14)
    ps = JuliaSyntax.ParseStream(src; version=VersionNumber(1, Int(vminor), 0))
    JuliaSyntax.parse!(ps; rule=:all)
    return [_node_event(n) for n in ps.output[2:end]]
end
