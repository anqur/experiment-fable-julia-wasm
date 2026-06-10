using WasmCodegen, WasmtimeRunner, WasmTools
const ENGINE = Engine()
function wasm_callable(f, argtypes::Type{<:Tuple})
    comp = compile_wasm(f, argtypes)
    validate_module(ENGINE, comp.bytes)
    store = Store(ENGINE); lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    argts = collect(argtypes.parameters)
    return (args...) -> wf(Any[WasmCodegen.to_wire(T, a) for (T, a) in zip(argts, args)]...)
end
outcome(f, args) = try (:value, f(args...)) catch err
        err isa Union{WasmTrap,WasmtimeError} ? (:error, :wasm) :
        err isa Exception ? (:error, Symbol(typeof(err))) : rethrow() end
function diffp(f, ats, cases; name=string(f))
    wf = try wasm_callable(f, ats) catch err
        err isa CompileError || rethrow()
        println("LOUD[$name]: ", err.msg); return
    end
    for args in cases
        n = outcome(f, args); w = outcome(wf, args)
        ok = n[1] === :error ? w[1] === :error :
             w[1] === :error ? false :
             (isequal(WasmCodegen.to_wire(typeof(n[2]), n[2]), w[2]) ||
              isequal(n[2], WasmCodegen.from_wire(typeof(n[2]), w[2])))
        println(ok ? "  ok " : "DIFF ", "[$name] args=$args native=$n wasm=$w")
    end
end

# undef phi edge: x only assigned on one path, read on the same condition
function undefphi(n::Int64)
    local x
    if n > 0
        x = n * 3
    end
    s = 0
    if n > 0
        s = x
    end
    return s
end
diffp(undefphi, Tuple{Int64}, [(5,), (-5,), (0,)])

# loop-carried phi where one rotation member is also used after the loop
function loopmix(n::Int64)
    a, b, c = 1, 2, 3
    while a < n
        a, b, c = a + b, c, a
    end
    return a * 1000000 + b * 1000 + c
end
diffp(loopmix, Tuple{Int64}, [(k,) for k in 0:10])

# === on immutable struct refs should be loud
struct ImmP; x::Int64; end
@noinline mkimm(x) = ImmP(x)
egalimm(x::Int64) = mkimm(x) === mkimm(x)
diffp(egalimm, Tuple{Int64}, [(1,)])
