# Fast driver for the lexer compile loop: prints the first blocking error.
using WasmCodegen
include(joinpath(@__DIR__, "lexdemo.jl"))
try
    comp = compile_wasm(lex_into, Tuple{String})
    println("COMPILED offloads=", length(comp.offloads),
            " funcs=", length(comp.wmod.funcs),
            " bytes=", length(comp.bytes))
    for off in comp.offloads
        println("  offload: ", off.name, " ", off.params, " -> ", off.results)
    end
catch e
    e isa CompileError || rethrow()
    showerror(stdout, e); println()
end
