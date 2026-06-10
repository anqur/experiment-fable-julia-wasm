# Probe: host function calling back into wasm on the same store (re-entrancy).
using WasmtimeRunner
using WasmTools, WasmTools.Instructions

m = WasmModule()
importfunc!(m, "host", "cb", FuncType([I64], [I64]))
addfunc!(m, "inner", FuncType([I64], [I64]), ValType[],
         [local_get(0), i64_const(10), i64_add()]; export_name="inner")
addfunc!(m, "outer", FuncType([I64], [I64]), ValType[],
         [local_get(0), call(0)]; export_name="outer")

eng = Engine(); store = Store(eng)
mod = CompiledModule(eng, encode(m))
lk = Linker(eng)
const INNER = Ref{Any}(nothing)
define_func!(lk, "host", "cb", [:i64], [:i64]) do x
    # re-enter wasm while a wasm->host call is on the stack
    INNER[](x) * 2
end
inst = instantiate(lk, store, mod)
INNER[] = inst["inner"]
v = inst["outer"](5)
println("reentrant call result = ", v, " (expected ", (5 + 10) * 2, ")")

# deeper recursion through the host boundary
m2 = WasmModule()
importfunc!(m2, "host", "rec", FuncType([I64], [I64]))
addfunc!(m2, "down", FuncType([I64], [I64]), ValType[],
         [local_get(0), call(0)]; export_name="down")
lk2 = Linker(eng)
const DOWN = Ref{Any}(nothing)
define_func!(lk2, "host", "rec", [:i64], [:i64]) do x
    x <= 0 ? Int64(0) : DOWN[](x - 1) + 1
end
inst2 = instantiate(lk2, store, CompiledModule(eng, encode(m2)))
DOWN[] = inst2["down"]
println("100-deep wasm<->host recursion = ", inst2["down"](100), " (expected 100)")

# funcref round-trip asymmetry: result of a funcref-returning call cannot be
# passed back as a funcref argument (from_cval gives CFunc, to_cval wants WasmFunc)
m3 = WasmModule()
t = addtype!(m3, FuncType([I64], [I64]))
addfunc!(m3, "f", FuncType([I64], [I64]), ValType[], [local_get(0)])
push!(m3.elems, Elem(:declared, FuncRefT, UInt32[0]))
addfunc!(m3, "getf", FuncType(ValType[], [FuncRefT]), ValType[],
         [ref_func(0)]; export_name="getf")
addfunc!(m3, "callf", FuncType([FuncRefT, I64], [I64]), ValType[],
         [local_get(1), local_get(0), ref_cast(t; nullable=false), call_ref(t)];
         export_name="callf")
inst3 = instantiate(store, CompiledModule(eng, encode(m3)))
fr = inst3["getf"]()
println("funcref result type: ", typeof(fr))
try
    println("callf(fr, 7) = ", inst3["callf"](fr, 7))
catch e
    println("funcref round-trip FAILED: ", sprint(showerror, e))
end
