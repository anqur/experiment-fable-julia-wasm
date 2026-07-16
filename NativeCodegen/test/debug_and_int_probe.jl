using NativeCodegen
using NativeCodegen: WasmInterp, compile_native, native_callable_from_so, CompileError
import Base.JuliaSyntax as JS

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

# Corpus snippets FIRST (these are the real goal), then stress tests last so a
# crash on the synthetic 4+-arg cases doesn't mask corpus results.
const INPUTS = [
    "1 + 2",
    "x = 1",
    "x = 1 + foo(y)",
    "module A\nend",
    "struct Point{T<:Real}\n  x::T\n  y::T\nend",
    "function f(a::Int, b)\n    return a * b - 2.5e3\nend",
    "try\n  risky()\ncatch e\n  rethrow()\nfinally\n  close(io)\nend",
    "[a[1] for a in xs if !isempty(a)]",
    # stress tests (may SIGILL — kept last)
    "1 + 2 + 3",
    "foo(a,b,c)",
    "foo(a,b,c,d)",
]

println("host ground truth:")
for src in INPUTS
    println("  ", repr(src), " => ", parse_into(src))
end
flush(stdout)

println("\ncompiling parse_into …")
comp = compile_native(parse_into, Tuple{String}; name="parse_into_corpus")
println("compiled.")
flush(stdout)
nf = native_callable_from_so(comp, Int64, String)

println("\nnative vs host:")
npass = 0
for src in INPUTS
    host = parse_into(src)
    print("  ", repr(src), " … "); flush(stdout)
    try
        native = nf(src)
        ok = native == host
        global npass += ok
        println(ok ? "✅" : "❌", "  host=", host, " native=", native)
    catch e
        if e isa InterruptException; rethrow(); end
        msg = sprint(showerror, e)
        length(msg) > 90 && (msg = msg[1:90] * "…")
        println("💥 ", typeof(e), ": ", msg)
    end
    flush(stdout)
end
println("\n", npass, "/", length(INPUTS), " passed")
rm(comp.so_path)
