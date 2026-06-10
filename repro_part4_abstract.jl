# Part 4: export with ABSTRACT anyref result — does WasmFunc wrapping survive?
using WasmTools
using WasmTools.Instructions
using WasmtimeRunner

eng = Engine(); store = Store(eng)
m = WasmModule()
addfunc!(m, "mki31", FuncType(ValType[], [AnyRefT]), ValType[],
         [i32_const(7), Inst(:ref_i31)]; export_name="mki31")
inst = instantiate(store, CompiledModule(eng, encode(m)))
println("instantiated; wrapping export with (result anyref)...")
f = inst["mki31"]
println("wrapped: ", f)
println("mki31() = ", repr(f()))
