# Part 2: exnref global. Run in its own process: wasmtime's C API ABORTS on
# wasmtime_global_get of an exnref global ("exnrefs not yet supported in C API").
using WasmtimeRunner

bytes = read(joinpath(@__DIR__, "globals.wasm"))  # module containing g_exn
eng = Engine()
mod = CompiledModule(eng, bytes)
store = Store(eng)
inst = instantiate(store, mod)
g_exn = exports(inst)["g_exn"]
which = get(ARGS, 1, "set")
if which == "get"
    println("calling g_exn[] (getindex) ...")
    flush(stdout)
    v = g_exn[]
    println("g_exn[] returned: ", repr(v))
else
    println("calling g_exn[] = nothing (setindex!) ...")
    flush(stdout)
    g_exn[] = nothing
    println("setindex! returned without error")
end
