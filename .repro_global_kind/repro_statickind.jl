# Probe the SUGGESTED FIX path: wasmtime_global_type -> wasm_globaltype_content
# -> wasm_valtype_kind, for the global named in ARGS[1].
using WasmtimeRunner
using WasmtimeRunner: CRef, libwasmtime

bytes = read(joinpath(@__DIR__, "globals2.wasm"))
eng = Engine()
mod = CompiledModule(eng, bytes)
store = Store(eng)
inst = instantiate(store, mod)
g = exports(inst)[ARGS[1]]

gt = ccall((:wasmtime_global_type, libwasmtime), Ptr{Cvoid},
           (Ptr{Cvoid}, Ref{CRef}), g.store.context, Ref(g.global_))
println("wasmtime_global_type ptr: ", gt); flush(stdout)
vt = ccall((:wasm_globaltype_content, libwasmtime), Ptr{Cvoid}, (Ptr{Cvoid},), gt)
println("wasm_globaltype_content ptr: ", vt, "; calling wasm_valtype_kind ...")
flush(stdout)
k = ccall((:wasm_valtype_kind, libwasmtime), UInt8, (Ptr{Cvoid},), vt)
println("wasm_valtype_kind(", ARGS[1], ") = ", Int(k))
