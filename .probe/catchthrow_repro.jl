# Probe: exception escaping _host_trampoline's catch block.
# The catch handler at runtime.jl:318-322 runs `sprint(showerror, err)`.
# If the thrown exception's showerror method itself throws, the secondary
# exception propagates out of the @cfunction into wasmtime's Rust frames.
using WasmtimeRunner
using WasmTools, WasmTools.Instructions

struct EvilError <: Exception end
# showerror that itself throws (simulates buggy user showerror / OOM in sprint)
Base.showerror(io::IO, ::EvilError) = error("showerror is buggy")

m = WasmModule()
importfunc!(m, "host", "boom", FuncType([I64], [I64]))
addfunc!(m, "go", FuncType([I64], [I64]), ValType[],
         [local_get(0), call(0)]; export_name="go")

eng = Engine(); store = Store(eng)
mod = CompiledModule(eng, encode(m))
lk = Linker(eng)
define_func!(lk, "host", "boom", [:i64], [:i64]) do x
    throw(EvilError())
end
inst = instantiate(lk, store, mod)

println("--- calling wasm export whose host import throws EvilError ---")
flush(stdout)
result = try
    inst["go"](1)
catch e
    println("caught at toplevel: ", typeof(e))
    :caught
end
println("survived call, result = ", result)
flush(stdout)

# If we get here, check whether the store/wasmtime state is still usable.
println("--- probing store state after the escape ---")
flush(stdout)
m2 = WasmModule()
addfunc!(m2, "id", FuncType([I64], [I64]), ValType[], [local_get(0)];
         export_name="id")
inst2 = instantiate(store, CompiledModule(eng, encode(m2)))
println("store still usable: id(42) = ", inst2["id"](42))
flush(stdout)
println("PROBE-COMPLETED-NORMALLY")
