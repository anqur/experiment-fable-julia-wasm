"""
    WasmtimeRunner

Julia embedding of the [wasmtime](https://wasmtime.dev) WebAssembly runtime via
its C API, with WasmGC, function references, tail calls, and exceptions enabled.

Supports loading/validating modules, instantiating them through a `Linker`,
calling exports, defining host functions backed by arbitrary Julia callables,
and binding Julia values into wasm as `externref`s — the basis for differential
testing of Julia-compiled wasm against native execution.

Library resolution order: `ENV["WASMTIME_LIB"]`, the vendored wasmtime v45
C API under `/workspace/tools/wasmtime-c-api`, then the `Wasmtime_jll` package
as a last resort.
"""
module WasmtimeRunner

using Libdl

function _find_libwasmtime()
    haskey(ENV, "WASMTIME_LIB") && return ENV["WASMTIME_LIB"]
    # Prefer the vendored v45 library: src/abi.jl and the ownership/threading
    # contracts in src/runtime.jl are verified against wasmtime v45.0.1
    # specifically. The currently-registered Wasmtime_jll is v39, whose C API
    # differs in load-bearing ways (wasmtime_context_gc returns void instead
    # of an error pointer, exnref globals abort the process, ...), so it is
    # only a fallback for environments without the vendored copy.
    vendored = "/workspace/tools/wasmtime-c-api/lib/libwasmtime.so"
    isfile(vendored) && return vendored
    jllid = Base.identify_package("Wasmtime_jll")
    if jllid !== nothing
        try
            jll = Base.require(jllid)
            return jll.libwasmtime::String
        catch
        end
    end
    error("libwasmtime not found: set ENV[\"WASMTIME_LIB\"], place the wasmtime " *
          "C API at $vendored, or install Wasmtime_jll")
end

const libwasmtime = _find_libwasmtime()

include("abi.jl")
include("runtime.jl")

export Engine, Store, CompiledModule, Linker, Instance,
       WasmFunc, WasmGlobal, WasmMemory, ExternRef,
       define_func!, instantiate, exports, validate_module, context,
       WasmtimeError, WasmTrap, store_gc!

end # module WasmtimeRunner
