# Adversarial differential tests for WasmCodegen silent-miscompilation review.
# Each candidate is run natively and under wasmtime; mismatches are printed.
using WasmCodegen
using WasmtimeRunner
using WasmTools

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
    return function (args...)
        wire = Any[WasmCodegen.to_wire(T, a) for (T, a) in zip(argts, args)]
        return wf(wire...)
    end
end

outcome(f, args) =
    try
        (:value, f(args...))
    catch err
        err isa Union{WasmTrap,WasmtimeError} && return (:error, :wasm)
        err isa Exception && return (:error, Symbol(typeof(err)))
        rethrow()
    end

function differential(f, argtypes::Type{<:Tuple}, cases; name=string(f))
    local wf
    try
        wf = wasm_callable(f, argtypes)
    catch err
        err isa CompileError || rethrow()
        println("LOUD[$name]: CompileError: $(err.msg)")
        return :loud
    end
    fails = 0
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
        if !ok
            fails += 1
            println("DIFF[$name]: args=$(args)  native=$(native)  wasm=$(wasm)")
        end
    end
    println(fails == 0 ? "PASS[$name]" : "FAIL[$name]: $fails mismatches")
    return fails == 0 ? :pass : :fail
end

# --- candidate functions (top-level) -----------------------------------------

# 1. sub-word checked sdiv: typemin ÷ -1 must throw DivideError
divi8(a::Int8, b::Int8) = a ÷ b
divi16(a::Int16, b::Int16) = a ÷ b

# 2. shift counts >= 2^32 on i32-storage values (count wrapped by i32.wrap_i64)
shl32(x::Int32, n::Int64) = x << n
shru8(x::UInt8, n::Int64) = x >> n
ashr64cnt(x::Int8, n::Int64) = Core.Intrinsics.ashr_int(x, n)

# 3. intrinsics with atypical signedness on sub-word reps
ashru8(x::UInt8, n::Int64) = Core.Intrinsics.ashr_int(x, n)
sltu8(x::UInt8, y::UInt8) = Core.Intrinsics.slt_int(x, y)
sleu8(x::UInt8, y::UInt8) = Core.Intrinsics.sle_int(x, y)
sextu8(x::UInt8) = Core.Intrinsics.sext_int(Int64, x)
sitofpu8(x::UInt8) = Core.Intrinsics.sitofp(Float64, x)

# 4. Bool normalization gap (emit_norm! skips Bool)
truncbool(x::Int64) = Core.Intrinsics.trunc_int(Bool, x)
addbool(a::Bool, b::Bool) = Core.Intrinsics.add_int(a, b)
modbool(x::Int64) = x % Bool   # lowers via and_int; expected to pass

# 5. Char representation: in-wasm Char is the codepoint, but bitcast pretends raw bits
charbits(c::Char) = reinterpret(UInt32, c)
charcp(c::Char) = UInt32(c)            # Base decode operates on raw bits

# 6. offload from_wire(Char): reinterpret of codepoint builds the wrong Char
@noinline hostcp(c::Char) = (s = string(c); Int64(codepoint(s[1])))
callhostcp(c::Char) = hostcp(c) + 0

# 7. muladd: native fuses (fma), wasm emits mul+add
mm(a::Float64, b::Float64, c::Float64) = muladd(a, b, c)

# 8. unsafe_trunc UB divergence (trunc_sat vs cvttsd2si)
utnan(x::Float64) = unsafe_trunc(Int64, x)
ut8(x::Float64) = unsafe_trunc(Int8, x)

# 9. CFG / phi stress (expected to pass)
function swapphi(n::Int64)
    a, b = 1, 2
    i = 0
    while i < n
        a, b = b, a
        i += 1
    end
    return a * 10 + b
end
function rotphi(n::Int64)
    a, b, c = 1, 2, 3
    i = 0
    while i < n
        a, b, c = c, a, b
        i += 1
    end
    return a * 100 + b * 10 + c
end
function diam(a::Int64, b::Int64)
    if a > b
        x = a - b; y = 1
    else
        x = b - a; y = 2
    end
    return x * y
end

# 10. checked arithmetic edges (expected to pass)
cm64(a::Int64, b::Int64) = Base.checked_mul(a, b)
cm32(a::Int32, b::Int32) = Base.checked_mul(a, b)
cm8(a::Int8, b::Int8) = Base.checked_mul(a, b)
ca8(a::Int8, b::Int8) = Base.checked_add(a, b)
csu8(a::UInt8, b::UInt8) = Base.checked_sub(a, b)
cmu64(a::UInt64, b::UInt64) = Base.checked_mul(a, b)

# 11. setfield! result value
mutable struct Ctr; n::Int64; end
function setres(x::Int64)
    c = Ctr(0)
    y = (c.n = x)
    return y + c.n
end

# --- run ----------------------------------------------------------------------

results = Dict{String,Symbol}()
r!(n, v) = (results[n] = v)

r!("divi8", differential(divi8, Tuple{Int8,Int8},
    [(Int8(-128), Int8(-1)), (Int8(-128), Int8(1)), (Int8(7), Int8(-2)), (Int8(1), Int8(0))]))
r!("divi16", differential(divi16, Tuple{Int16,Int16},
    [(Int16(-32768), Int16(-1)), (Int16(100), Int16(-7))]))

r!("shl32", differential(shl32, Tuple{Int32,Int64},
    [(Int32(1), 4294967296), (Int32(1), 4294967297), (Int32(1), 2), (Int32(-5), 31),
     (Int32(1), -4294967296)]))
r!("shru8", differential(shru8, Tuple{UInt8,Int64},
    [(UInt8(0x80), 4294967297), (UInt8(0x80), 3), (UInt8(0x80), 8)]))
r!("ashr64cnt", differential(ashr64cnt, Tuple{Int8,Int64},
    [(Int8(-128), 4294967296), (Int8(-128), 2)]))

r!("ashru8", differential(ashru8, Tuple{UInt8,Int64},
    [(UInt8(0x80), 1), (UInt8(0x80), 7), (UInt8(0x40), 1), (UInt8(0xff), 100)]))
r!("sltu8", differential(sltu8, Tuple{UInt8,UInt8},
    [(UInt8(0x80), UInt8(0x01)), (UInt8(0x01), UInt8(0x80)), (UInt8(0x7f), UInt8(0x80))]))
r!("sleu8", differential(sleu8, Tuple{UInt8,UInt8},
    [(UInt8(0x80), UInt8(0x01)), (UInt8(0x01), UInt8(0x80))]))
r!("sextu8", differential(sextu8, Tuple{UInt8}, [(UInt8(0xff),), (UInt8(0x7f),)]))
r!("sitofpu8", differential(sitofpu8, Tuple{UInt8}, [(UInt8(0xff),), (UInt8(0x10),)]))

r!("truncbool", differential(truncbool, Tuple{Int64}, [(6,), (7,), (0,), (1,), (2,)]))
r!("addbool", differential(addbool, Tuple{Bool,Bool},
    [(true, true), (true, false), (false, false)]))
r!("modbool", differential(modbool, Tuple{Int64}, [(6,), (7,), (0,)]))

r!("charbits", differential(charbits, Tuple{Char}, [('a',), ('λ',), ('∀',)]))
r!("charcp", differential(charcp, Tuple{Char}, [('a',), ('λ',), ('∀',)]))
r!("callhostcp", differential(callhostcp, Tuple{Char}, [('a',), ('λ',)]))

r!("muladd", differential(mm, Tuple{Float64,Float64,Float64},
    [(1.0 + 2.0^-52, 1.0 + 2.0^-52, -(1.0 + 2.0^-51)), (2.0, 3.0, 4.0)]))

r!("utnan", differential(utnan, Tuple{Float64}, [(NaN,), (1.0e300,), (-1.0e300,), (2.5,)]))
r!("ut8", differential(ut8, Tuple{Float64}, [(1.0e12,), (200.0,), (-300.0,)]))

r!("swapphi", differential(swapphi, Tuple{Int64}, [(n,) for n in 0:5]))
r!("rotphi", differential(rotphi, Tuple{Int64}, [(n,) for n in 0:7]))
r!("diam", differential(diam, Tuple{Int64,Int64}, [(3, 5), (5, 3), (4, 4)]))

mn8, mx8 = typemin(Int8), typemax(Int8)
r!("cm64", differential(cm64, Tuple{Int64,Int64},
    [(typemin(Int64), -1), (-1, typemin(Int64)), (typemin(Int64), 1), (0, typemin(Int64)),
     (3037000500, 3037000499), (-3037000500, 3037000500)]))
r!("cm32", differential(cm32, Tuple{Int32,Int32},
    [(typemin(Int32), Int32(-1)), (Int32(-1), typemin(Int32)), (Int32(46341), Int32(46341)),
     (Int32(46340), Int32(46340))]))
r!("cm8", differential(cm8, Tuple{Int8,Int8},
    [(mn8, Int8(-1)), (Int8(-1), mn8), (Int8(16), Int8(8)), (Int8(11), Int8(11)),
     (Int8(-12), Int8(11)), (Int8(0), mn8)]))
r!("ca8", differential(ca8, Tuple{Int8,Int8},
    [(mx8, Int8(1)), (mn8, Int8(-1)), (Int8(100), Int8(27)), (Int8(-100), Int8(-28))]))
r!("csu8", differential(csu8, Tuple{UInt8,UInt8},
    [(UInt8(1), UInt8(2)), (UInt8(2), UInt8(1)), (UInt8(0), UInt8(255))]))
r!("cmu64", differential(cmu64, Tuple{UInt64,UInt64},
    [(UInt64(0), UInt64(5)), (typemax(UInt64), UInt64(2)), (UInt64(2)^32, UInt64(2)^32)]))

r!("setres", differential(setres, Tuple{Int64}, [(5,), (-3,)]))

println("\n==== summary ====")
for k in sort!(collect(keys(results)))
    println(rpad(k, 12), results[k])
end
