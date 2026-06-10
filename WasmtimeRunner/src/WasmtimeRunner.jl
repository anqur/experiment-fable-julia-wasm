"""
    WasmtimeRunner

Julia embedding of the [wasmtime](https://wasmtime.dev) WebAssembly runtime via
its C API, with WasmGC, function references, tail calls, and exceptions enabled.

Supports loading/validating modules, instantiating them through a `Linker`,
calling exports, defining host functions backed by arbitrary Julia callables,
and binding Julia values into wasm as `externref`s — the basis for differential
testing of Julia-compiled wasm against native execution.

Library resolution order: `ENV["WASMTIME_LIB"]`, then `Wasmtime_jll` (pinned
to v45: src/abi.jl and the ownership/threading contracts in src/runtime.jl are
verified against wasmtime v45.0.1 specifically).
"""
module WasmtimeRunner

using Libdl
using Wasmtime_jll: Wasmtime_jll

function _find_libwasmtime()
    haskey(ENV, "WASMTIME_LIB") && return ENV["WASMTIME_LIB"]
    return Wasmtime_jll.libwasmtime::String
end

const libwasmtime = _find_libwasmtime()

include("abi.jl")
include("runtime.jl")

export Engine, Store, CompiledModule, Linker, Instance,
       WasmFunc, WasmGlobal, WasmMemory, ExternRef, OpaqueExtern,
       define_func!, define_global!, instantiate, exports, validate_module, context,
       WasmtimeError, WasmTrap, store_gc!, string_codec

end # module WasmtimeRunner
