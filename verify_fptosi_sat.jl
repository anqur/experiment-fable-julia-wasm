# Independent minimal repro: fptosi/fptoui lowered as trunc_sat vs native cvttsd2si.
using WasmCodegen, WasmtimeRunner, WasmTools

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

outcome(f, args) =
    try
        (:value, f(args...))
    catch err
        err isa Union{WasmTrap,WasmtimeError} && return (:error, :wasmtrap)
        err isa Exception && return (:error, Symbol(typeof(err)))
        rethrow()
    end

ndiff = 0
function check(f, argtypes, cases; name=string(f))
    global ndiff
    wf = wasm_callable(f, argtypes)
    argts = collect(argtypes.parameters)
    for args in cases
        native = outcome(f, args)
        wasm = outcome(wf, args)
        ok = if native[1] === :error
            wasm[1] === :error
        elseif wasm[1] === :error
            false
        else
            nval, wval = native[2], wasm[2]
            isequal(WasmCodegen.to_wire(typeof(nval), nval), wval) ||
                isequal(nval, WasmCodegen.from_wire(typeof(nval), wval))
        end
        tag = ok ? "OK  " : "DIFF"
        ok || (ndiff += 1)
        println("$tag [$name] args=$(args) native=$(native) wasm=$(wasm)")
    end
end

# --- unsafe_trunc: result documented as "an arbitrary value" when inexact ----
ut64(x::Float64)  = unsafe_trunc(Int64, x)
utu64(x::Float64) = unsafe_trunc(UInt64, x)
ut32(x::Float64)  = unsafe_trunc(Int32, x)
ut8(x::Float64)   = unsafe_trunc(Int8, x)

check(ut64,  Tuple{Float64}, [(NaN,), (1e300,), (-1e300,), (3.9,), (-3.9,)])
check(utu64, Tuple{Float64}, [(NaN,), (1e300,), (-1.5,), (3.9,)])
check(ut32,  Tuple{Float64}, [(NaN,), (1e300,), (2.5e9,), (3.9,)])
check(ut8,   Tuple{Float64}, [(1e12,), (200.0,), (-3.9,), (42.0,)])

# --- defined-behavior controls: checked conversions must already agree -------
ck64(x::Float64) = Int64(x)         # InexactError for NaN/out-of-range/fractional
tr64(x::Float64) = trunc(Int64, x)  # InexactError for NaN/out-of-range
rnd(x::Float64)  = round(Int64, x)

check(ck64, Tuple{Float64}, [(3.0,), (2.5,), (NaN,), (1e300,), (-0.0,)])
check(tr64, Tuple{Float64}, [(3.9,), (-3.9,), (NaN,), (1e300,), (9.007199254740992e15,)])
check(rnd,  Tuple{Float64}, [(2.5,), (3.5,), (-2.5,), (NaN,), (1e300,)])

println(ndiff == 0 ? "NO DIVERGENCE" : "TOTAL DIFFS: $ndiff")
