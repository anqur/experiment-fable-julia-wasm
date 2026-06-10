"""
    WasmCodegen

Translator from Julia's optimized SSA IR (`IRCode`) to WebAssembly, built on
WasmTools. Engine-agnostic: produces wasm binaries plus a description of the
host imports ("offloads") needed to run them, so the same module can run under
wasmtime (see WasmtimeRunner) or in a browser.

```julia
comp = compile_wasm(f, Tuple{Int64,Int64})
comp.bytes              # the wasm binary
comp.entry              # exported function name
offload_imports(comp)   # host imports to bind before instantiating
```
"""
module WasmCodegen

using WasmTools
using WasmTools.Instructions

"""Raised when a Julia construct has no wasm translation (yet)."""
struct CompileError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CompileError) = print(io, "CompileError: ", e.msg)

include("reprs.jl")
include("intrinsics.jl")
include("compiler.jl")

export compile_wasm, WasmCompilation, offload_imports, CompileError

end # module WasmCodegen
