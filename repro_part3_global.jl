# Part 3: anyref via exported GLOBALS (path that skips wasm_valtype_kind).
using WasmTools
using WasmTools.Instructions
using WasmtimeRunner

eng = Engine(); store = Store(eng)
m = WasmModule()
pair = addtype!(m, StructType([FieldType(I64, false)]))
# two immutable anyref globals initialized to distinct structs
push!(m.globals, Global(GlobalType(typeref(pair; nullable=true), false),
                        [i64_const(1), struct_new(pair)]))
push!(m.globals, Global(GlobalType(typeref(pair; nullable=true), false),
                        [i64_const(2), struct_new(pair)]))
push!(m.exports, Export("g1", :global, 0))
push!(m.exports, Export("g2", :global, 1))
inst = instantiate(store, CompiledModule(eng, encode(m)))
g1 = inst["g1"]; g2 = inst["g2"]
v1 = g1[]; v2 = g2[]
println("g1[] = ", repr(v1))
println("g2[] = ", repr(v2))
println("isequal(g1[], g2[]) = ", isequal(v1, v2),
        "   (underlying structs hold 1 vs 2)")
@assert v1 === :anyref && v2 === :anyref && isequal(v1, v2)
println("CONFIRMED: distinct WasmGC struct values both collapse to :anyref, isequal == true")
