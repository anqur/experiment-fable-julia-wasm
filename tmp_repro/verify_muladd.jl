# Minimal differential repro: muladd_float lowering (mul+add) vs native fused muladd.
# Run: export JULIA_DEPOT_PATH=/workspace/.julia:$HOME/.julia
#      julia --project=/workspace /workspace/tmp_repro/verify_muladd.jl
using WasmCodegen, WasmtimeRunner

mm(a::Float64, b::Float64, c::Float64) = muladd(a, b, c)
mm32(a::Float32, b::Float32, c::Float32) = muladd(a, b, c)

function wasm_callable(f, argtypes)
    eng = Engine()
    comp = compile_wasm(f, argtypes)
    store = Store(eng)
    lk = Linker(eng)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(eng, comp.bytes))
    return inst[comp.entry]
end

wf = wasm_callable(mm, Tuple{Float64,Float64,Float64})
a = 1 + 2.0^-52; b = a; c = -(1 + 2.0^-51)
native = mm(a, b, c)
wasm   = wf(a, b, c)
println("case f64: a=b=1+2^-52, c=-(1+2^-51)")
println("  native muladd = ", native)
println("  wasm   muladd = ", wasm)
println("  fma reference = ", fma(a, b, c))
println("  isequal       = ", isequal(native, wasm))

wf32 = wasm_callable(mm32, Tuple{Float32,Float32,Float32})
a32 = 1 + Float32(2.0^-23); c32 = -(1 + Float32(2.0^-22))
n32 = mm32(a32, a32, c32); w32 = wf32(a32, a32, c32)
println("case f32: a=b=1+2^-23, c=-(1+2^-22)")
println("  native muladd = ", n32)
println("  wasm   muladd = ", w32)
println("  isequal       = ", isequal(n32, w32))

exit(isequal(native, wasm) && isequal(n32, w32) ? 0 : 1)
