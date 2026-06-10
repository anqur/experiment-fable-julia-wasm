# Minimal independent differential repro for: shift counts >= 2^32 on
# i32-storage values are wrapped by i32.wrap_i64 before the width check.
using WasmCodegen, WasmtimeRunner

const ENGINE = Engine()

function wasm_callable(f, argtypes::Type{<:Tuple})
    comp = compile_wasm(f, argtypes)
    store = Store(ENGINE)
    lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    argts = collect(argtypes.parameters)
    return (args...) -> wf(Any[WasmCodegen.to_wire(T, a) for (T, a) in zip(argts, args)]...)
end

shl32(x::Int32, n::Int64)  = x << n            # Base << passes the count through
shru8(x::UInt8, n::Int64)  = x >> n
ashr8(x::Int8, n::Int64)   = Core.Intrinsics.ashr_int(x, n)
shlu32(x::UInt32, n::UInt64) = x << n          # plain unsigned count path

fails = 0
function check(name, f, T::Type{<:Tuple}, wf, args)
    native = f(args...)
    raw = wf(args...)
    wasm = WasmCodegen.from_wire(typeof(native), raw)
    ok = isequal(native, wasm)
    ok || (global fails += 1)
    println("$(ok ? "OK  " : "DIFF") $name$(args): native=$(repr(native)) wasm=$(repr(wasm))")
end

w_shl32 = wasm_callable(shl32, Tuple{Int32,Int64})
w_shru8 = wasm_callable(shru8, Tuple{UInt8,Int64})
w_ashr8 = wasm_callable(ashr8, Tuple{Int8,Int64})
w_shlu32 = wasm_callable(shlu32, Tuple{UInt32,UInt64})

# sanity: in-range counts must agree
check("shl32", shl32, Tuple{Int32,Int64}, w_shl32, (Int32(1), 4))
check("shl32", shl32, Tuple{Int32,Int64}, w_shl32, (Int32(1), 40))      # >=32, fits i32
# the bug: counts whose low 32 bits are small but value >= 2^32
check("shl32", shl32, Tuple{Int32,Int64}, w_shl32, (Int32(1), Int64(2)^32))
check("shl32", shl32, Tuple{Int32,Int64}, w_shl32, (Int32(1), Int64(2)^32 + 1))
check("shl32", shl32, Tuple{Int32,Int64}, w_shl32, (Int32(1), -Int64(2)^32)) # negative -> >> by 2^32
check("shru8", shru8, Tuple{UInt8,Int64}, w_shru8, (UInt8(0x80), Int64(2)^32 + 1))
check("ashr8", ashr8, Tuple{Int8,Int64},  w_ashr8, (Int8(-128), Int64(2)^32))
check("shlu32", shlu32, Tuple{UInt32,UInt64}, w_shlu32, (UInt32(1), UInt64(2)^32))

println(fails == 0 ? "ALL MATCH (refuted)" : "$fails DIVERGENCES (confirmed)")
