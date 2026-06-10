# Repro for: funcref values cannot round-trip through the WasmtimeRunner API.
# Native-Julia analogue: f = x -> x + 1; passing f back to a caller works.
# Expected (correct) wasm behavior: getf() returns a callable funcref handle that
# can be passed to callf; via_host(41) == 42.
using WasmtimeRunner

wasm = read(joinpath(@__DIR__, "funcref_roundtrip.wasm"))

engine = Engine()
store = Store(engine)
mod = CompiledModule(engine, wasm)
linker = Linker(engine)

# Host echo: receives a funcref arg, returns it unchanged.
host_seen = Ref{Any}(nothing)
define_func!(linker, "host", "echo", [:funcref], [:funcref]) do fr
    host_seen[] = fr
    return fr
end

inst = instantiate(linker, store, mod)
getf  = inst["getf"]
callf = inst["callf"]
via_host = inst["via_host"]

# --- Case 1: export returns funcref; pass it back into an export ---
fr = getf()
println("getf() returned: ", typeof(fr), " => ", fr)
case1 = try
    r = callf(fr, Int64(41))
    println("callf(fr, 41) = ", r, "  (expected 42)")
    r == 42 ? :ok : :wrong_value
catch e
    println("callf(fr, 41) THREW: ", typeof(e), ": ", sprint(showerror, e))
    :threw
end

# Sanity: a WasmFunc-wrapped handle DOES work, proving the wasm side is fine.
case1b = try
    wf = WasmFunc(store, fr)   # manual wrap of the raw CFunc
    r = callf(wf, Int64(41))
    println("callf(WasmFunc(store, fr), 41) = ", r, "  (manual wrap works)")
    r == 42 ? :ok : :wrong_value
catch e
    println("manual-wrap call THREW: ", sprint(showerror, e))
    :threw
end

# --- Case 2: host function receives funcref arg and echoes it as result ---
case2 = try
    r = via_host(Int64(41))
    println("via_host(41) = ", r, "  (expected 42)")
    r == 42 ? :ok : :wrong_value
catch e
    println("via_host(41) THREW: ", typeof(e), ": ", sprint(showerror, e))
    :threw
end
println("host saw funcref arg as: ", typeof(host_seen[]))

println()
println("RESULT case1 (export->export round-trip): ", case1)
println("RESULT case1b (manual WasmFunc wrap):      ", case1b)
println("RESULT case2 (host echo round-trip):       ", case2)
if case1 === :threw || case2 === :threw
    println("BUG CONFIRMED: funcref values do not round-trip")
    exit(1)
else
    println("NO BUG: round-trip succeeded")
    exit(0)
end
