# Differential test: the wasm-compiled JuliaSyntax parser vs the native one.
# Compares the full event stream (tokens AND tree ranges) on a corpus that
# includes malformed and partial inputs.
using WasmCodegen, WasmtimeRunner
include(joinpath(@__DIR__, "parsedemo.jl"))

comp = compile_wasm(parse_into, Tuple{String})
println("module: ", length(comp.bytes), " bytes, ", length(comp.wmod.funcs),
        " funcs, ", length(comp.offloads), " offloads, ",
        length(comp.hostconsts), " host consts")
write(joinpath(@__DIR__, "parser.wasm"), comp.bytes)

eng = Engine()
validate_module(eng, comp.bytes)
store = Store(eng)
lk = Linker(eng)
for (mod, name, params, results, thunk) in offload_imports(comp)
    define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
end
for (name, v) in comp.hostconsts
    define_global!(lk, store, "julia", name, v)
end
inst = instantiate(lk, store, CompiledModule(eng, comp.bytes))
wf = inst[comp.entry]
codec = string_codec(inst)
WasmCodegen.string_bridge[] = codec

function wasm_events(src::String)
    empty!(TOKEN_SINK[])
    empty!(NODE_SINK[])
    wf(codec.fromstring(src))
    return copy(TOKEN_SINK[]), copy(NODE_SINK[])
end

corpus = [
    "x = 1 + foo(y)",
    "",
    "function f(a::Int, b)\n    return a * b - 2.5e3\nend",
    "s = \"string with \$interp and \\\\ escape\"",
    "# a comment\nif x ≤ 3 && y .|> z\n  @m a..b c...\nend",
    "0x1f 0b101 1_000_000 3.14f0 1e-9 'c' '\\u03b1'",
    "module M; export f!; const Λ = [1,2]'; end",
    "a ⊕ b ⟺ c −d ⋅e",
    "\"\"\"triple \\\" string\"\"\" `cmd \$x` var\"weird name\"",
    "let x=1; while x<10; x+=1; end; end # 🚀 emoji",
    "f(x) do y\n  y^2\nend",
    "[a[1] for a in xs if !isempty(a)]",
    # parser-heavy constructs
    "struct Point{T<:Real}\n  x::T\n  y::T\nend",
    "abstract type A end; primitive type P 8 end; mutable struct M end",
    "for (i, x) in enumerate(xs)\n  s += x > 0 ? x : -x\nend",
    "try\n  risky()\ncatch e\n  rethrow()\nfinally\n  close(io)\nend",
    "macro m(ex...)\n  esc(:(\$(ex...)))\nend",
    "f(; a=1, b...) = g(a; b...)",
    "x.y.z[i][j].w = a' .+ b .* c",
    "if a; elseif b; else; end",
    "quote\n  \$x + \$(y...)\nend",
    "T where {S, T<:AbstractArray{S}}",
    "(a, (b, c)) = t; a, b = b, a",
    "@inbounds @views xs[2:end] .= ys[1:end-1]",
    "function (obj::Foo)(args...; kw=1)\n  obj.f(args..., kw)\nend",
    "let; global g = [i^2 for i in 1:10 if iseven(i)]; end",
    "baremodule B\nimport ..M: f, g as h\nusing X\nend",
    "ccall((:fn, \"lib\"), Cint, (Cdouble,), x)",
    "r\"regex\"m * raw\"no \\escape\" * b\"bytes\"",
    "1.5 < x <= 2^-3 != y === z",
    "do_block() do; nothing end",
    "if true\n  0x1.8p3 + 1e1000 + 1f-50\nend",      # float edge cases incl over/underflow
    # malformed / partial inputs (error recovery paths)
    "wrong = 1.2.3 .+ 0xg \"unterminated",
    "function f(",
    "begin\n  x +\nend",
    "struct S",
    "a ? b",
    "for i in\nend",
    "x = '∀∃' * 'ab'",                # overlong char literals
    "f(a,, b)",
    "\"\\q bad escape\" '\\q'",
    "x** y",
    "1_000_ .+e",
    "module\nend",
    "@ macro_missing_name",
    "x = 1e310",                       # overflow diagnostics
]

fails = 0
for src in corpus
    nat = native_events(src)
    was = try
        wasm_events(src)
    catch e
        (sprint(showerror, e),)
    end
    if isequal(nat, was)
        println("ok   ", length(nat[1]), " tokens, ", length(nat[2]),
                " nodes: ", repr(first(src, 40)))
    else
        global fails += 1
        println("FAIL ", repr(src))
        if length(was) == 1
            println("  wasm error: ", was[1])
        else
            for (what, a, b) in (("token", nat[1], was[1]), ("node", nat[2], was[2]))
                length(a) == length(b) ||
                    println("  $what count: native ", length(a), " vs wasm ", length(b))
                for (k, (x, y)) in enumerate(zip(a, b))
                    isequal(x, y) ||
                        (println("  first $what diff at ", k, ": ", x, " vs ", y); break)
                end
            end
        end
    end
end
println(fails == 0 ? "\nPARSER MATCHES NATIVE on all $(length(corpus)) inputs." :
        "\n$fails inputs disagree")
exit(fails == 0 ? 0 : 1)
