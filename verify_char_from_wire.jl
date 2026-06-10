# Minimal independent repro: from_wire(Char, v) corrupts Char arguments to
# offloaded host functions. Differential test wasm vs native.
using WasmCodegen
using WasmtimeRunner

const ENGINE = Engine()
const RECEIVED = Char[]   # record exactly what Char the host function sees

# Body uses string ops -> cannot compile to wasm -> gets offloaded to host.
@noinline hosteq(c::Char) = (push!(RECEIVED, c); s = string(c); Int64(s == "a"))
calleq(c::Char) = hosteq(c) * 10 + 1

@noinline hostcp(c::Char) = (s = string(c); Int64(codepoint(s[1])))
callcp(c::Char) = hostcp(c) + 0

function wasm_callable(f, argtypes)
    comp = compile_wasm(f, argtypes)
    @assert !isempty(comp.offloads) "expected callee to be offloaded"
    store = Store(ENGINE)
    lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    return c -> wf(WasmCodegen.to_wire(Char, c))
end

fails = 0
weq = wasm_callable(calleq, Tuple{Char})
wcp = wasm_callable(callcp, Tuple{Char})
for c in ('a', 'b', 'λ')
    native = calleq(c)
    wasm = weq(c)
    ok = isequal(native, wasm)
    global fails += !ok
    println("calleq($(repr(c))): native=$native wasm=$wasm ", ok ? "OK" : "MISMATCH")
end
for c in ('a', 'λ')
    native = callcp(c)
    wasm = wcp(c)
    ok = isequal(native, wasm)
    global fails += !ok
    println("callcp($(repr(c))): native=$native wasm=$wasm ", ok ? "OK" : "MISMATCH")
end
println("host received Chars: ", repr(RECEIVED))
println(fails == 0 ? "ALL PASS" : "$fails MISMATCHES -> bug confirmed")

# Direct boundary probe, no wasm execution involved: round-trip through the
# actual offload thunk for hostcp.
comp = compile_wasm(callcp, Tuple{Char})
(_, _, _, _, thunk) = only(offload_imports(comp))
wire = WasmCodegen.to_wire(Char, 'a')   # what wasm passes for 'a'
println("thunk(to_wire('a')=$(wire)) = ", thunk(wire), "   (native hostcp('a') = ", hostcp('a'), ")")
println("from_wire(Char, $(wire)) = ", repr(WasmCodegen.from_wire(Char, wire)),
        "  ismalformed=", Base.ismalformed(WasmCodegen.from_wire(Char, wire)))
