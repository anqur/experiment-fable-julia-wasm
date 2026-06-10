using WasmCodegen, WasmtimeRunner, WasmTools

const ENGINE = Engine()

mutable struct NodeQ; v::Int64; end
pickref(c::Bool, x::Int64, y::Int64) = Core.ifelse(c, NodeQ(x), NodeQ(y)).v

# Check the optimized IR actually contains Core.ifelse (not folded to a branch)
ir, _ = only(Base.code_ircode(pickref, Tuple{Bool,Int64,Int64}))
println("--- optimized IR ---")
println(ir)

println("--- compile_wasm ---")
comp = try
    compile_wasm(pickref, Tuple{Bool,Int64,Int64})
catch err
    println("COMPILE-TIME ERROR (", typeof(err), "): ", sprint(showerror, err))
    exit(0)
end
println("compile_wasm succeeded; module size = ", length(comp.bytes), " bytes")

println("--- wasmtime validate ---")
try
    validate_module(ENGINE, comp.bytes)
    println("validation OK")
catch err
    println("VALIDATION ERROR (", typeof(err), "): ", sprint(showerror, err))
end

# also run through wasm-tools validate for an independent check
path = "/workspace/tmp_repro/ifelse_ref_select.wasm"
write(path, comp.bytes)
println("--- wasm-tools validate ---")
run(ignorestatus(`/workspace/tools/wasm-tools-dist/wasm-tools validate --features all $path`))

# If it somehow validates, run differentially
println("--- attempt execution ---")
try
    store = Store(ENGINE); lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    for args in [(true, 1, 2), (false, 1, 2)]
        n = pickref(args...)
        w = wf(Any[WasmCodegen.to_wire(T, a) for (T, a) in zip((Bool, Int64, Int64), args)]...)
        println((args, :native, n, :wasm, w, isequal(n, w) ? "ok" : "DIFF"))
    end
catch err
    println("RUNTIME/INSTANTIATION ERROR (", typeof(err), "): ", sprint(showerror, err))
end
