# JSRuntime differential tests: every corpus function runs natively (JSString
# = UTF-16 code units) and compiled to wasm under wasmtime, where the
# "wasm:js-string" imports are bound to the same native implementations.
# A JSON manifest + .wasm files are also written for the V8 side
# (test_node.mjs), where the imports are real JS strings — either the
# engine's js-string builtins or the polyfill in test_node.mjs.
using Test
using JSRuntime
using WasmCodegen
using WasmtimeRunner

const ENGINE = Engine()

function wasm_callable(f, argtypes)
    comp = compile_wasm(f, argtypes)
    validate_module(ENGINE, comp.bytes)
    store = Store(ENGINE)
    lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params),
                     collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    argts = collect(argtypes.parameters)
    return comp, function (args...)
        wire = Any[a isa JSString ? a : WasmCodegen.to_wire(T, a)
                   for (T, a) in zip(argts, args)]
        return wf(wire...)
    end
end

outcome(f, args) =
    try
        (:value, f(args...))
    catch err
        err isa Union{WasmTrap,WasmtimeError} && return (:error, :wasm)
        err isa Exception && return (:error, :julia)
        rethrow()
    end

# --- corpus -------------------------------------------------------------------

jlen(s::JSString) = jslength(s)
ccat(s::JSString, i::Int32) = charcodeat(s, i)
cpat(s::JSString, i::Int32) = codepointat(s, i)
catlen(a::JSString, b::JSString) = jslength(concat(a, b))
subeq(s::JSString, a::Int32, b::Int32, t::JSString) =
    jsequals(substring(s, a, b), t)

function count_units(s::JSString, c::Int32)
    n = jslength(s)
    cnt = Int32(0)
    i = Int32(0)
    while i < n
        charcodeat(s, i) == c && (cnt += Int32(1))
        i += Int32(1)
    end
    return cnt
end

"""Reverse by code unit (surrogates intentionally break — exactly as the
equivalent JS would); exercises string-building via concat/fromCharCode."""
function reverse_units(s::JSString)
    out = substring(s, Int32(0), Int32(0))   # empty
    i = jslength(s) - Int32(1)
    while i >= Int32(0)
        out = concat(out, fromcharcode(charcodeat(s, i)))
        i -= Int32(1)
    end
    return out
end

function alphabet(n::Int32)
    out = fromcodepoint(Int32(65))
    i = Int32(1)
    while i < n
        out = concat(out, fromcodepoint(Int32(65) + i))
        i += Int32(1)
    end
    return out
end

const HELLO = "hello world"
const MUSIC = "a" * "\U1D11E" * "b"   # U+1D11E is a surrogate pair in UTF-16

const CORPUS = [
    ("jlen", jlen, Tuple{JSString}, [(JSString(HELLO),), (JSString(""),),
                                     (JSString(MUSIC),)]),
    ("ccat", ccat, Tuple{JSString,Int32},
     [(JSString(HELLO), Int32(0)), (JSString(HELLO), Int32(10)),
      (JSString(HELLO), Int32(11)),            # OOB: trap on both sides
      (JSString(HELLO), Int32(-1)),            # unsigned wrap: OOB
      (JSString(MUSIC), Int32(1))]),           # lone high surrogate unit
    ("cpat", cpat, Tuple{JSString,Int32},
     [(JSString(MUSIC), Int32(1)),             # full code point 0x1D11E
      (JSString(MUSIC), Int32(2)),             # lone low surrogate
      (JSString(MUSIC), Int32(0))]),
    ("catlen", catlen, Tuple{JSString,JSString},
     [(JSString("ab"), JSString("cde")), (JSString(""), JSString(""))]),
    ("subeq", subeq, Tuple{JSString,Int32,Int32,JSString},
     [(JSString(HELLO), Int32(6), Int32(11), JSString("world")),
      (JSString(HELLO), Int32(6), Int32(99), JSString("world")),   # clamped
      (JSString(HELLO), Int32(8), Int32(2), JSString("")),         # a > b
      (JSString(HELLO), Int32(0), Int32(5), JSString("world"))]),
    ("count_units", count_units, Tuple{JSString,Int32},
     [(JSString(HELLO), Int32(108)), (JSString(HELLO), Int32(122))]),
    ("reverse_units", reverse_units, Tuple{JSString},
     [(JSString(HELLO),), (JSString(""),)]),
    ("alphabet", alphabet, Tuple{Int32}, [(Int32(5),), (Int32(1),)]),
]

# --- native vs wasmtime ---------------------------------------------------------

manifest = []
@testset "JSString builtins: native vs wasmtime" begin
    for (name, f, argtypes, cases) in CORPUS
        comp, wf = wasm_callable(f, argtypes)
        write(joinpath(@__DIR__, "jsstr_$name.wasm"), comp.bytes)
        # spec-exact builtin signatures ((ref extern) results) for engines
        # with strict builtin type checks; same module otherwise
        exact = compile_wasm(f, argtypes; exact_engine_imports=true)
        write(joinpath(@__DIR__, "jsstr_$(name)_exact.wasm"), exact.bytes)
        jscases = []
        for args in cases
            native = outcome(f, args)
            wasm = outcome(wf, args)
            if native[1] === :error
                @test wasm[1] === :error
            else
                @test wasm[1] === :value && isequal(native[2], wasm[2])
            end
            jsargs = [a isa JSString ? String(a) : Int(a) for a in args]
            expected = native[1] === :error ? Dict("error" => true) :
                       native[2] isa JSString ? String(native[2]) : Int(native[2])
            push!(jscases, Dict("args" => jsargs, "expected" => expected,
                                "stringarg" => [a isa JSString for a in args],
                                "stringret" => native[1] === :value &&
                                               native[2] isa JSString))
        end
        push!(manifest, Dict("name" => name, "wasm" => "jsstr_$name.wasm",
                             "entry" => comp.entry, "cases" => jscases))
    end
end

# manifest for the V8 side
import Base: write
function _json(io, x)
    if x isa Dict
        print(io, "{")
        for (k, (key, val)) in enumerate(pairs(x))
            k > 1 && print(io, ",")
            print(io, "\"", key, "\":")
            _json(io, val)
        end
        print(io, "}")
    elseif x isa AbstractVector
        print(io, "[")
        for (k, v) in enumerate(x)
            k > 1 && print(io, ",")
            _json(io, v)
        end
        print(io, "]")
    elseif x isa AbstractString
        print(io, repr(x))   # Julia escapes are JSON-compatible for our data
    elseif x isa Bool || x isa Number
        print(io, x)
    else
        error("unsupported $x")
    end
end
open(joinpath(@__DIR__, "jsstr_manifest.json"), "w") do io
    _json(io, manifest)
end

# --- V8 (node) ------------------------------------------------------------------

node = Sys.which("node")
if node !== nothing
    @testset "JSString builtins: V8" begin
        mjs = joinpath(@__DIR__, "test_node.mjs")
        # Node 22 gates the js-string builtins behind a V8 flag; without it
        # (or on engines lacking the option) the test falls back to the
        # polyfill on its own
        ok = success(run(ignorestatus(
            `$node --experimental-wasm-imported-strings $mjs`)))
        ok || (ok = success(run(ignorestatus(`$node $mjs`))))
        @test ok
    end
else
    @info "node not found; skipping the V8 differential"
end
