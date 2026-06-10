# Part 1: anyref + v128 globals (no exnref, which aborts the process; see repro_exn.jl)
using WasmtimeRunner
using WasmtimeRunner: CVal, CRef, libwasmtime, WASMTIME_ANYREF, WASMTIME_V128

bytes = read(joinpath(@__DIR__, "globals2.wasm"))
eng = Engine()
mod = CompiledModule(eng, bytes)
store = Store(eng)
inst = instantiate(store, mod)
ex = exports(inst)

g_any, g_v128, g_i64 = ex["g_any"], ex["g_v128"], ex["g_i64"]

g_i64[] = 42
println("control g_i64[] after set: ", g_i64[], " (expect 42)")

function rawkind(g)
    cur = Ref(CVal())
    ccall((:wasmtime_global_get, libwasmtime), Cvoid,
          (Ptr{Cvoid}, Ref{CRef}, Ref{CVal}), g.store.context, Ref(g.global_), cur)
    k = cur[].kind
    k == WASMTIME_ANYREF && WasmtimeRunner._unroot_val(cur[])
    return Int(k)
end
println("raw kinds: g_any=", rawkind(g_any), " (ANYREF=", Int(WASMTIME_ANYREF),
        "), g_v128=", rawkind(g_v128), " (V128=", Int(WASMTIME_V128), ")")

function trysetx(label, g, x)
    try
        g[] = x
        println(label, ": SUCCEEDED (silently accepted)")
    catch e
        println(label, ": threw ", typeof(e), ": ", sprint(showerror, e))
    end
end

trysetx("g_any[] = nothing ", g_any, nothing)   # natural 'set to null'
trysetx("g_any[] = 5       ", g_any, 5)
trysetx("g_v128[] = 0      ", g_v128, 0)

println("wasm-side any_is_null() = ", ex["any_is_null"](), " (expect 1: untouched)")
ex["set_any_i31"](Int32(9))
println("after wasm-internal set, any_is_null() = ", ex["any_is_null"](), " (expect 0)")
println("g_any[] via getindex: ", repr(g_any[]))

flush(stdout)
