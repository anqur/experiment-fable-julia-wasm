"""
    WasmtimeRunner

Julia embedding of the [wasmtime](https://wasmtime.dev) WebAssembly runtime via
its C API, with WasmGC, function references, tail calls, and exceptions enabled.

Supports loading/validating modules, instantiating them through a `Linker`,
calling exports, defining host functions backed by arbitrary Julia callables,
and binding Julia values into wasm as `externref`s — the basis for differential
testing of Julia-compiled wasm against native execution.

Library resolution order: `ENV["WASMTIME_LIB"]`, the `Wasmtime_jll` package (if
installed in the active project), then the vendored wasmtime C API under
`/workspace/tools/wasmtime-c-api`.
"""
module WasmtimeRunner

using Libdl

function _find_libwasmtime()
    haskey(ENV, "WASMTIME_LIB") && return ENV["WASMTIME_LIB"]
    # Prefer Wasmtime_jll when it is available in the load path (the JLL for
    # wasmtime v45 is registering; until then we fall back to the vendored copy).
    jllid = Base.identify_package("Wasmtime_jll")
    if jllid !== nothing
        try
            jll = Base.require(jllid)
            return jll.libwasmtime::String
        catch
        end
    end
    vendored = "/workspace/tools/wasmtime-c-api/lib/libwasmtime.so"
    isfile(vendored) && return vendored
    error("libwasmtime not found: set ENV[\"WASMTIME_LIB\"], install Wasmtime_jll, " *
          "or place the wasmtime C API at $vendored")
end

const libwasmtime = _find_libwasmtime()

include("abi.jl")
include("runtime.jl")

export Engine, Store, CompiledModule, Linker, Instance,
       WasmFunc, WasmGlobal, WasmMemory, ExternRef,
       define_func!, instantiate, exports, validate_module, context,
       WasmtimeError, WasmTrap, store_gc!

end # module WasmtimeRunner
