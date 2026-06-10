# Part 2: WasmCodegen entry returning a Tuple -> what actually happens?
using WasmtimeRunner, WasmCodegen
mkpair(a::Int64, b::Int64) = (a, b)
eng = Engine()
comp = compile_wasm(mkpair, Tuple{Int64,Int64})
validate_module(eng, comp.bytes)
println("module compiled and validated; entry = ", comp.entry)
st = Store(eng)
inst = instantiate(st, CompiledModule(eng, comp.bytes))
println("instantiated ok; now wrapping export (this is where WasmFunc queries the functype)...")
wf = inst[comp.entry]
println("wrapped: ", wf)
println("wasm mkpair(3,4) = ", repr(wf(3, 4)))
println("wasm mkpair(5,6) = ", repr(wf(5, 6)))
println("isequal = ", isequal(wf(3, 4), wf(5, 6)))
