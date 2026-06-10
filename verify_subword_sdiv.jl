# Minimal independent repro: sub-word checked sdiv (Julia `div`) at typemin/-1.
# Native Julia throws DivideError; claim is that wasm silently returns typemin.
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
        err isa Union{WasmTrap,WasmtimeError} && return (:trap, sprint(showerror, err))
        (:exception, string(typeof(err)))
    end

divi8(a::Int8, b::Int8)    = a ÷ b
divi16(a::Int16, b::Int16) = a ÷ b
divi32(a::Int32, b::Int32) = a ÷ b   # control: 32-bit should trap natively in wasm
divi64(a::Int64, b::Int64) = a ÷ b   # control

mismatches = 0
function check(f, argtypes, args)
    global mismatches
    wf = wasm_callable(f, argtypes)
    native = outcome(f, args)
    wasm = outcome(wf, args)
    agree = (native[1] === :value && wasm[1] === :value &&
             isequal(WasmCodegen.to_wire(typeof(native[2]), native[2]), wasm[2])) ||
            (native[1] === :exception && wasm[1] === :trap)
    agree || (mismatches += 1)
    println(rpad(string(f), 7), " args=", args,
            "  native=", native, "  wasm=", wasm, "  ", agree ? "OK" : "MISMATCH")
end

check(divi8,  Tuple{Int8,Int8},   (typemin(Int8),  Int8(-1)))
check(divi8,  Tuple{Int8,Int8},   (Int8(7),        Int8(0)))    # div-by-zero control
check(divi8,  Tuple{Int8,Int8},   (Int8(-127),     Int8(-1)))   # non-overflow control
check(divi16, Tuple{Int16,Int16}, (typemin(Int16), Int16(-1)))
check(divi32, Tuple{Int32,Int32}, (typemin(Int32), Int32(-1)))
check(divi64, Tuple{Int64,Int64}, (typemin(Int64), Int64(-1)))

println(mismatches == 0 ? "ALL AGREE" : "MISMATCHES: $mismatches")
exit(mismatches == 0 ? 0 : 1)
