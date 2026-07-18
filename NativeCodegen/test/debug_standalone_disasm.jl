# Phase 0 disasm check: a struct-allocating function (category A type tag) must
# NO LONGER bake pointer_from_objref(Point) as an immediate — it should call
# __jl_type_tag instead. (String literals are still baked — category C, Phase 2.)

using NativeCodegen

mutable struct DisasmPoint
    x::Int64
    y::Int64
end
mkpt()::DisasmPoint = DisasmPoint(42, 99)

comp = compile_native(mkpt, Tuple{}; name="mkpt")
SO = "/tmp/ncg_phase0_mkpt.so"
cp(comp.so_path, SO)
println("saved: ", SO)
println("symbol: ", comp.func_name)
println("baked ptr of DisasmPoint type = 0x", string(reinterpret(UInt64, pointer_from_objref(DisasmPoint)); base=16))
