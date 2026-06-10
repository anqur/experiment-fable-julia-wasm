# Differential test: the wasm-compiled JuliaSyntax lexer vs the native one.
using WasmCodegen, WasmtimeRunner
include(joinpath(@__DIR__, "lexdemo.jl"))

comp = compile_wasm(lex_into, Tuple{String})
println("module: ", length(comp.bytes), " bytes, ", length(comp.wmod.funcs),
        " funcs, ", length(comp.offloads), " offloads, ",
        length(comp.hostconsts), " host consts")
write(joinpath(@__DIR__, "lexer.wasm"), comp.bytes)

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

function wasm_tokens(src::String)
    empty!(TOKEN_SINK[])
    n = wf(codec.fromstring(src))
    return copy(TOKEN_SINK[])
end

corpus = [
    "x = 1 + foo(y)",
    "",
    "function f(a::Int, b)\n    return a * b - 2.5e3\nend",
    "s = \"string with \$interp and \\\\ escape\"",
    "# a comment\nif x ≤ 3 && y .|> z\n  @m a..b c...\nend",
    "0x1f 0b101 1_000_000 3.14f0 1e-9 'c' '\\u03b1'",
    "module M; export f!; const Λ = [1,2]'; end",
    "a ⊕ b ⟺ c −d ⋅e",                    # unicode ops incl. canonicalized ones
    "\"\"\"triple \\\" string\"\"\" `cmd \$x` var\"weird name\"",
    "let x=1; while x<10; x+=1; end; end # 🚀 emoji",
    "α₁β = :sym; 'q' :  ? .. -->",
    "f(x) do y\n  y^2\nend",
    "[a[1] for a in xs if !isempty(a)]",
    "wrong = 1.2.3 .+ 0xg \"unterminated",
]

fails = 0
for src in corpus
    nat = native_tokens(src)
    was = wasm_tokens(src)
    if nat == was
        println("ok   ", length(nat), " tokens: ", repr(first(src, 30)))
    else
        global fails += 1
        println("FAIL ", repr(src))
        println("  native: ", nat[1:min(end,8)])
        println("  wasm:   ", was[1:min(end,8)])
        for (k, (a, b)) in enumerate(zip(nat, was))
            a == b || (println("  first diff at token ", k, ": ", a, " vs ", b); break)
        end
    end
end
println(fails == 0 ? "\nLEXER MATCHES NATIVE on all $(length(corpus)) inputs." :
        "\n$fails inputs disagree")
exit(fails == 0 ? 0 : 1)
