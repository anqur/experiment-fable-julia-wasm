using WasmCodegen, WasmtimeRunner, WasmTools
include_string(Main, read("/workspace/review_diff.jl", String)[1:0]) # noop
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

# === on mixed scalar types (inference may fold)
egal_mixed(x::Int8, y::UInt8) = x === y
diffp(egal_mixed, Tuple{Int8,UInt8}, [(Int8(1), UInt8(1)), (Int8(-1), UInt8(255))])

# setfield! on a const field of a mutable struct
mutable struct CF; const a::Int64; b::Int64; end
function setconst(x::Int64)
    c = CF(1, 2)
    setfield!(c, :a, x)
    return c.a
end
diffp(setconst, Tuple{Int64}, [(5,)])

# zext_int on Char (raw-bits vs codepoint family)
zextchar(c::Char) = Core.Intrinsics.zext_int(UInt64, c)
diffp(zextchar, Tuple{Char}, [('a',), ('λ',)])

# offload Bool/UInt round trips
@noinline hostbool(x::Int64) = length(string(x)) > 2
callhostbool(x::Int64) = hostbool(x) ? 1 : 0
diffp(callhostbool, Tuple{Int64}, [(5,), (500,)])
@noinline hostu8(x::UInt8) = UInt8(length(string(x)))
callhostu8(x::UInt8) = hostu8(x) + UInt8(1)
diffp(callhostu8, Tuple{UInt8}, [(UInt8(7),), (UInt8(200),)])
@noinline hostneg(x::Int8) = Int8(-length(string(x)))
callhostneg(x::Int8) = hostneg(x)
diffp(callhostneg, Tuple{Int8}, [(Int8(-100),)])

# Bool returned from offload arriving back into wasm and used
@noinline hostflag(x::Int64) = isodd(length(string(x)))
useflag(x::Int64) = hostflag(x) ? x + 1 : x - 1
diffp(useflag, Tuple{Int64}, [(5,), (50,), (500,)])

# float32 NaN payload / -0.0 identity
negz(x::Float64) = x === -0.0
diffp(negz, Tuple{Float64}, [(0.0,), (-0.0,), (NaN,)])

# ifelse on Union-ref types (should be loud, checking)
mutable struct NodeQ; v::Int64; end
pickref(c::Bool, x::Int64, y::Int64) = Core.ifelse(c, NodeQ(x), NodeQ(y)).v
diffp(pickref, Tuple{Bool,Int64,Int64}, [(true, 1, 2), (false, 1, 2)])
