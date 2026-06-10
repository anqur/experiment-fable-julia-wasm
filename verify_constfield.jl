# Independent verification: setfield! on a const field of a mutable struct.
# Native Julia must throw ErrorException; if wasm returns a value, the finding
# is confirmed (silent wrong-semantics divergence).
using WasmCodegen, WasmtimeRunner, WasmTools

mutable struct CF
    const a::Int64
    b::Int64
end

function setconst(x::Int64)
    c = CF(1, 2)
    setfield!(c, :a, x)
    return c.a
end

# 1. What does native Julia do?
native = try
    (:value, setconst(5))
catch err
    (:error, typeof(err), sprint(showerror, err))
end
println("native: ", native)

# 2. What does inference say about the setfield! statement?
ci, rt = only(Base.code_typed(setconst, Tuple{Int64}))
println("inferred return type: ", rt)
for (idx, stmt) in enumerate(ci.code)
    println("  %", idx, " = ", stmt, " :: ", ci.ssavaluetypes[idx])
end

# 3. Compile to wasm and run under wasmtime.
const ENGINE = Engine()
comp = compile_wasm(setconst, Tuple{Int64})
validate_module(ENGINE, comp.bytes)
store = Store(ENGINE)
lk = Linker(ENGINE)
for (mod, name, params, results, thunk) in offload_imports(comp)
    define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
end
inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
wf = inst[comp.entry]
wasm = try
    (:value, wf(WasmCodegen.to_wire(Int64, 5)))
catch err
    err isa Union{WasmTrap,WasmtimeError} ? (:error, :wasmtrap) : rethrow()
end
println("wasm:   ", wasm)

if native[1] === :error && wasm[1] === :error
    println("RESULT: MATCH (both error) -> finding REFUTED")
elseif native[1] === :error && wasm[1] === :value
    println("RESULT: DIVERGENCE native throws, wasm returns ", wasm[2], " -> finding CONFIRMED")
else
    println("RESULT: unexpected combination")
end
