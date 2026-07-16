import Base.JuliaSyntax as JS

# Wrap host parse_RtoL to log entry/exit next_byte. HOST ONLY (no native compile).
const _orig = JS.parse_RtoL
const LOG = Ref(true)
function JS.parse_RtoL(ps::JS.ParseState, a...; )
    nb0 = ps.stream.next_byte
    LOG[] && println(stderr, "[RtoL in ] next_byte=$nb0  (handlers=$(typeof.(a)))")
    r = _orig(ps, a...)
    nb1 = ps.stream.next_byte
    LOG[] && println(stderr, "[RtoL out] next_byte=$nb1  (Δ=$(nb1-nb0))")
    return r
end

_head_bits(h::JS.SyntaxHead) =
    Int64(reinterpret(UInt16, JS.kind(h))) | (Int64(JS.flags(h)) << 16)
function parse_into(src::String)
    ps = JS.ParseStream(src)
    JS.parse!(ps)
    out = ps.output
    i = 2
    while i <= length(out)
        n = @inbounds out[i]
        ev = (_head_bits(getfield(n, :head)),
              Int64(getfield(n, :byte_span)),
              Int64(getfield(n, :node_span_or_orig_kind)))
        i += 1
    end
    return Int64(length(out) - 1)
end

for src in ("a + b + c", "a + b + c + d")
    println(stderr, "\n========== HOST parse_into $src ==========")
    c = parse_into(src)
    println(stderr, "host count: $c")
end
