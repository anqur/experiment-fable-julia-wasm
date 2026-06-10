# Repro for: WasmGlobal setindex! infers global kind from current value;
# anyref/exnref/v128 fall back to :i64 in the kind Dict.
using WasmtimeRunner
using WasmtimeRunner: CVal, CRef, libwasmtime,
    WASMTIME_ANYREF, WASMTIME_EXNREF, WASMTIME_V128, WASMTIME_I64

bytes = read(joinpath(@__DIR__, "globals.wasm"))
eng = Engine()
mod = CompiledModule(eng, bytes)
store = Store(eng)
inst = instantiate(store, mod)
ex = exports(inst)

g_any, g_exn, g_v128, g_i64 = ex["g_any"], ex["g_exn"], ex["g_v128"], ex["g_i64"]

# --- control: i64 global works ------------------------------------------------
g_i64[] = 42
println("control g_i64[] after set: ", g_i64[], " (expect 42)")

# --- probe what kind byte wasmtime_global_get reports for each global ---------
function rawkind(g)
    cur = Ref(CVal())
    ccall((:wasmtime_global_get, libwasmtime), Cvoid,
          (Ptr{Cvoid}, Ref{CRef}, Ref{CVal}), g.store.context, Ref(g.global_), cur)
    k = cur[].kind
    k in (WASMTIME_ANYREF, WASMTIME_EXNREF) && WasmtimeRunner._unroot_val(cur[])
    return k
end
println("raw kinds: g_any=", rawkind(g_any), " (ANYREF=", Int(WASMTIME_ANYREF),
        "), g_exn=", rawkind(g_exn), " (EXNREF=", Int(WASMTIME_EXNREF),
        "), g_v128=", rawkind(g_v128), " (V128=", Int(WASMTIME_V128), ")")

# --- the buggy paths -----------------------------------------------------------
function trysetx(label, g, x)
    try
        g[] = x
        println(label, ": SUCCEEDED (value silently accepted!)")
    catch e
        println(label, ": threw ", typeof(e), ": ", sprint(showerror, e))
    end
end

# Natural use: null out an anyref global
trysetx("g_any[] = nothing       ", g_any, nothing)
# Set with an integer (would be plausible for an i31-typed slot)
trysetx("g_any[] = 5             ", g_any, 5)
trysetx("g_exn[] = nothing       ", g_exn, nothing)
trysetx("g_v128[] = 0            ", g_v128, 0)

# --- silent-corruption check: did wasm-side state change? ----------------------
println("wasm-side any_is_null() = ", ex["any_is_null"](), " (expect 1: untouched)")
ex["set_any_i31"](Int32(9))                       # set from inside wasm: fine
println("after wasm-internal set, any_is_null() = ", ex["any_is_null"](),
        " (expect 0)")
println("g_any[] read back via getindex: ", repr(g_any[]))
