# Minimal independent repro: Bool results escape un-normalized from
# trunc_int(Bool, x) and add_int on Bool (emit_norm! skips Bool, intrinsics.jl:29).
# Differential: native Julia vs wasmtime execution of compiled wasm.
using WasmCodegen
using WasmtimeRunner

const ENGINE = Engine()

function wasm_callable(f, argtypes::Type{<:Tuple})
    comp = compile_wasm(f, argtypes)
    validate_module(ENGINE, comp.bytes)
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

# 1. Raw Bool result crossing the wire.
truncbool(x::Int64) = Core.Intrinsics.trunc_int(Bool, x)
addbool(a::Bool, b::Bool) = Core.Intrinsics.add_int(a, b)
# 2. Bad Bool consumed *inside* wasm -> divergence observable as plain Int64
#    (no wire-conversion ambiguity).
truncbool_branch(x::Int64) = Core.Intrinsics.trunc_int(Bool, x) ? Int64(1) : Int64(2)
truncbool_zext(x::Int64) = Core.Intrinsics.zext_int(Int64, Core.Intrinsics.trunc_int(Bool, x))
addbool_branch(a::Bool, b::Bool) = Core.Intrinsics.add_int(a, b) ? Int64(10) : Int64(20)
# 3. Control: `% Bool` lowers through and_int and should agree.
modbool(x::Int64) = x % Bool

ndiff = 0
function check(f, argtypes, cases)
    global ndiff
    wf = wasm_callable(f, argtypes)
    for args in cases
        native = f(args...)
        wire = wf(args...)
        decoded = WasmCodegen.from_wire(typeof(native), wire)
        agree = isequal(WasmCodegen.to_wire(typeof(native), native), wire) ||
                isequal(native, decoded)
        println("$(f)$(args): native=$(repr(native)) wasm_wire=$(repr(wire)) decoded=$(repr(decoded)) => ", agree ? "OK" : "DIFF")
        agree || (ndiff += 1)
    end
end

check(truncbool, Tuple{Int64}, [(Int64(6),), (Int64(2),), (Int64(3),), (Int64(0),)])
check(addbool, Tuple{Bool,Bool}, [(true, true), (true, false), (false, false)])
check(truncbool_branch, Tuple{Int64}, [(Int64(6),), (Int64(3),)])
check(truncbool_zext, Tuple{Int64}, [(Int64(6),), (Int64(3),)])
check(addbool_branch, Tuple{Bool,Bool}, [(true, true), (true, false)])
check(modbool, Tuple{Int64}, [(Int64(6),), (Int64(3),)])

println(ndiff == 0 ? "NO DIVERGENCE" : "CONFIRMED: $ndiff divergences from native Julia")
