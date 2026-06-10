# Fast driver for the parser compile loop: prints the first blocking error.
using WasmCodegen
include(joinpath(@__DIR__, "parsedemo.jl"))
try
    comp = compile_wasm(parse_into, Tuple{String})
    println("COMPILED offloads=", length(comp.offloads),
            " funcs=", length(comp.wmod.funcs),
            " consts=", length(comp.hostconsts),
            " bytes=", length(comp.bytes))
    for off in comp.offloads
        println("  offload: ", off.name, " ", off.params, " -> ", off.results)
    end
catch e
    e isa CompileError || rethrow()
    showerror(stdout, e); println()
end
