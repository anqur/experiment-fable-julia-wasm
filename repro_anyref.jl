# Repro for: anyref/exnref results collapse to the symbols :anyref/:exnref
using WasmTools
using WasmTools.Instructions
using WasmtimeRunner

println("=== Part 1: runner-level — two distinct WasmGC structs ===")
eng = Engine(); store = Store(eng)
m = WasmModule()
pair = addtype!(m, StructType([FieldType(I64, false)]))
# mk1() -> (ref null $pair) holding 1 ; mk2 holding 2
addfunc!(m, "mk1", FuncType(ValType[], [typeref(pair; nullable=true)]), ValType[],
         [i64_const(1), struct_new(pair)]; export_name="mk1")
addfunc!(m, "mk2", FuncType(ValType[], [typeref(pair; nullable=true)]), ValType[],
         [i64_const(2), struct_new(pair)]; export_name="mk2")
# in-wasm proof the two values differ
addfunc!(m, "fieldof1", FuncType(ValType[], [I64]), ValType[],
         [i64_const(1), struct_new(pair), struct_get(pair, 0)]; export_name="fieldof1")
addfunc!(m, "fieldof2", FuncType(ValType[], [I64]), ValType[],
         [i64_const(2), struct_new(pair), struct_get(pair, 0)]; export_name="fieldof2")
inst = instantiate(store, CompiledModule(eng, encode(m)))
r1 = inst["mk1"]()
r2 = inst["mk2"]()
println("mk1() = ", repr(r1))
println("mk2() = ", repr(r2))
println("isequal(mk1(), mk2()) = ", isequal(r1, r2),
        "   (wasm-side fields: ", inst["fieldof1"](), " vs ", inst["fieldof2"](), ")")
@assert r1 === :anyref && r2 === :anyref && isequal(r1, r2)

println()
println("=== Part 2: end-to-end — WasmCodegen entry returning a struct (Tuple) ===")
using WasmCodegen
mkpair(a::Int64, b::Int64) = (a, b)
comp = compile_wasm(mkpair, Tuple{Int64,Int64})
validate_module(eng, comp.bytes)
st2 = Store(eng)
inst2 = instantiate(st2, CompiledModule(eng, comp.bytes))
wf = inst2[comp.entry]
println("export signature: ", wf)
w34 = wf(3, 4)
w56 = wf(5, 6)
println("wasm mkpair(3,4) = ", repr(w34), "   native = ", repr(mkpair(3, 4)))
println("wasm mkpair(5,6) = ", repr(w56), "   native = ", repr(mkpair(5, 6)))
println("isequal(wasm(3,4), wasm(5,6)) = ", isequal(w34, w56),
        "  <-- distinct results indistinguishable")

println()
println("=== Part 3: what the repo's differential harness would do ===")
# replicate WasmCodegen/test/runtests.jl lines 52-54 comparison
nval, wval = mkpair(3, 4), w34
try
    ok = isequal(WasmCodegen.to_wire(typeof(nval), nval), wval) ||
         isequal(nval, WasmCodegen.from_wire(typeof(nval), wval))
    println("harness comparison returned: ", ok, (ok ? "  <-- SILENT FALSE PASS" : "  <-- ordinary failure"))
catch err
    println("harness comparison THREW: ", sprint(showerror, err))
end
