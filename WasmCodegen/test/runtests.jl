using Test
using WasmCodegen
using WasmtimeRunner
using WasmTools

# --- differential harness -----------------------------------------------------
# Run f natively and in wasmtime; values must agree (isequal), and an error on
# one side must be an error on the other (wasm traps ~ Julia exceptions).

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
    rt = nothing
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
        err isa Exception && return (:error, :julia)
        rethrow()
    end

"""Compare wasm vs native for each argument tuple. Returns failures."""
function differential(f, argtypes::Type{<:Tuple}, cases; name=string(f))
    wf = wasm_callable(f, argtypes)
    argts = collect(argtypes.parameters)
    fails = []
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
        ok || push!(fails, (args, native, wasm))
    end
    isempty(fails) || foreach(x -> println(stderr, "DIFF[$name]: args=$(x[1]) native=$(x[2]) wasm=$(x[3])"), fails)
    return fails
end

macro difftest(f, argtypes, cases)
    quote
        @test isempty(differential($(esc(f)), $(esc(argtypes)), $(esc(cases))))
    end
end


# Corpus functions must be top-level: local recursive functions are closures.
function mygcd(a::Int64, b::Int64)
    while b != 0
        a, b = b, a % b
    end
    return a < 0 ? -a : a
end
function collatz(n::Int64)
    steps = 0
    while n != 1 && steps < 1000
        n = iseven(n) ? n ÷ 2 : 3n + 1
        steps += 1
    end
    return steps
end
function fibloop(n::Int64)
    a, b = 0, 1
    for _ in 1:n
        a, b = b, a + b
    end
    return a
end
function nested(a::Int64, b::Int64)
    acc = 0
    for i in 1:a
        for j in 1:b
            if (i + j) % 3 == 0
                acc += i * j
            elseif (i * j) % 5 == 1
                acc -= j
            end
        end
    end
    return acc
end
myfib(n::Int64) = n <= 1 ? n : myfib(n - 1) + myfib(n - 2)
function ack(m::Int64, n::Int64)
    m == 0 && return n + 1
    n == 0 && return ack(m - 1, 1)
    return ack(m - 1, ack(m, n - 1))
end
isev(n::Int64)::Bool = n == 0 ? true : isod(n - 1)
isod(n::Int64)::Bool = n == 0 ? false : isev(n - 1)
@noinline function hostside(n::Int64)
    s = string(n)            # not compilable to wasm
    return Int64(length(s))
end
caller(n) = hostside(n * 2) + 1
sideeffect_free(x::Int64) = nothing
function checkedfn(a::Int64, b::Int64)
    x = Base.checked_add(a, 1)
    return x ÷ b
end

# --- corpus -------------------------------------------------------------------

i64s = Int64[0, 1, -1, 2, -2, 7, -63, 64, 1023, -4096, typemax(Int64),
             typemin(Int64), typemax(Int64) - 1, 123456789, -987654321]
pairs64 = [(a, b) for a in i64s[1:8] for b in i64s[1:8]]

@testset "straight-line arithmetic" begin
    poly(a, b) = a * a + 3a * b - b + 7
    @difftest poly Tuple{Int64,Int64} pairs64
    mix(a, b) = (a + b) ⊻ (a - b) | (a & b) % (b | 1)
    @difftest mix Tuple{Int64,Int64} pairs64
    u(a, b) = (a + b) * (a ⊻ 0x1234)
    @difftest u Tuple{UInt64,UInt64} [(UInt64(a), UInt64(b)) for (a,b) in
        [(0,0), (1,2), (typemax(UInt64), 1), (0x8000000000000000, 0xffffffffffffffff)]]
end

@testset "comparisons and Bool" begin
    cmp1(a, b) = a < b
    @difftest cmp1 Tuple{Int64,Int64} pairs64
    cmp2(a, b) = (a <= b) == (b >= a) && a != b
    @difftest cmp2 Tuple{Int64,Int64} pairs64
    cmpu(a, b) = a < b ? a : b
    @difftest cmpu Tuple{UInt64,UInt64} [(UInt64(1), UInt64(2)),
        (typemax(UInt64), UInt64(1)), (UInt64(0x8000000000000000), UInt64(1))]
    bnot(a) = !(a > 0)
    @difftest bnot Tuple{Int64} [(x,) for x in i64s]
end

@testset "division and checked ops" begin
    qd(a, b) = a ÷ b + a % b
    @difftest qd Tuple{Int64,Int64} [(a, b) for a in i64s for b in i64s]   # incl. ÷0, typemin÷-1
    uqd(a, b) = a ÷ b
    @difftest uqd Tuple{UInt64,UInt64} [(UInt64(7), UInt64(2)), (UInt64(7), UInt64(0)),
                                        (typemax(UInt64), UInt64(3))]
end

@testset "control flow" begin
    @difftest mygcd Tuple{Int64,Int64} [(12, 18), (17, 5), (0, 0), (0, 5), (5, 0),
                                        (-12, 18), (12, -18), (-12, -18),
                                        (typemax(Int64), typemax(Int64) - 1)]
    @difftest collatz Tuple{Int64} [(n,) for n in 1:50]
    @difftest fibloop Tuple{Int64} [(n,) for n in 0:30]
    @difftest nested Tuple{Int64,Int64} [(5, 7), (0, 9), (12, 12), (1, 1)]
end

@testset "recursion via invoke" begin
    @difftest myfib Tuple{Int64} [(n,) for n in 0:20]
    @difftest ack Tuple{Int64,Int64} [(0, 0), (1, 3), (2, 3), (3, 3)]
end

@testset "multi-function (mutual recursion)" begin
    @difftest isev Tuple{Int64} [(n,) for n in 0:7]
end

@testset "floats" begin
    horner(x) = @evalpoly(x, 1.0, -2.0, 3.0, -4.0)
    @difftest horner Tuple{Float64} [(x,) for x in
        [0.0, -0.0, 1.0, -1.5, 1e10, -1e-10, Inf, -Inf, NaN, eps()]]
    fcmp(a, b) = a < b ? a + b : a * b
    @difftest fcmp Tuple{Float64,Float64} [(a, b) for a in [-1.5, 0.0, NaN, Inf]
                                                   for b in [2.5, -0.0, NaN, -Inf]]
    sq(x) = sqrt(x * x + 1.0)
    @difftest sq Tuple{Float64} [(x,) for x in [0.0, 3.0, -4.0, 1e154]]
    f32arith(a, b) = a * b + Float32(1.5)
    @difftest f32arith Tuple{Float32,Float32} [(1.0f0, 2.0f0), (Inf32, 0.0f0)]
end

@testset "conversions" begin
    c1(x) = Float64(x) * 0.5
    @difftest c1 Tuple{Int64} [(x,) for x in i64s]
    c2(x) = Int32(x & 0x7fffffff)
    @difftest c2 Tuple{Int64} [(x,) for x in i64s if x >= 0]
    c3(x) = unsafe_trunc(Int64, x)
    @difftest c3 Tuple{Float64} [(1.9,), (-2.9,), (0.0,)]
    c4(x) = Int64(x)   # checked conversion: errors on non-integral / overflow
    @difftest c4 Tuple{Float64} [(3.0,), (3.5,), (1e300,), (-0.0,)]
    widen32(x) = Int64(x) + 1
    @difftest widen32 Tuple{Int32} [(Int32(5),), (typemax(Int32),), (Int32(-7),)]
end

@testset "shifts (total semantics)" begin
    sh1(x, n) = x << n
    sh2(x, n) = x >> n
    sh3(x, n) = x >>> n
    shiftcases = [(x, n) for x in Int64[1, -1, 0x12345, typemin(Int64)]
                          for n in Int64[0, 1, 31, 63, 64, 65, 100, -1]]
    @difftest sh1 Tuple{Int64,Int64} shiftcases
    @difftest sh2 Tuple{Int64,Int64} shiftcases
    @difftest sh3 Tuple{Int64,Int64} shiftcases
end

@testset "bit counting" begin
    bits(x) = leading_zeros(x) + trailing_zeros(x) * 3 + count_ones(x) * 5
    @difftest bits Tuple{Int64} [(x,) for x in i64s]
    bits32(x) = leading_zeros(x) + count_ones(x)
    @difftest bits32 Tuple{UInt32} [(UInt32(0),), (UInt32(1),), (typemax(UInt32),)]
end

@testset "sub-word integers" begin
    b1(x, y) = x + y * x - y
    @difftest b1 Tuple{UInt8,UInt8} [(UInt8(a), UInt8(b)) for a in [0, 1, 127, 200, 255]
                                                           for b in [0, 1, 5, 255]]
    @difftest b1 Tuple{Int8,Int8} [(Int8(a), Int8(b)) for a in [-128, -1, 0, 1, 127]
                                                       for b in [-128, 0, 3, 127]]
    b2(x) = x ÷ UInt8(3) + x % UInt8(7)
    @difftest b2 Tuple{UInt8} [(UInt8(x),) for x in [0, 1, 100, 255]]
    b3(x, n) = (x << n) | (x >> n)
    @difftest b3 Tuple{UInt8,Int64} [(UInt8(0xAB), n) for n in [0, 1, 7, 8, 9, 63]]
    b4(x) = abs(x)
    @difftest b4 Tuple{Int64} [(x,) for x in i64s]
end

@testset "ifelse and flipsign" begin
    fs(a, b) = flipsign(a, b)
    @difftest fs Tuple{Int64,Int64} pairs64
    ie(a, b) = ifelse(a > b, a - b, b - a)
    @difftest ie Tuple{Int64,Int64} pairs64
end

@testset "errors must match" begin
    # native throws OverflowError / DivideError; wasm must trap
    @difftest checkedfn Tuple{Int64,Int64} [(1, 2), (typemax(Int64), 1), (1, 0)]
end

@testset "offload to host" begin
    comp = compile_wasm(caller, Tuple{Int64})
    @test length(comp.offloads) == 1
    @test occursin("hostside", comp.offloads[1].name)
    wf = wasm_callable(caller, Tuple{Int64})
    @test wf(21) == caller(21)
    @test wf(-500) == caller(-500)
end

@testset "Nothing returns and ghost values" begin
    wf = wasm_callable(sideeffect_free, Tuple{Int64})
    @test wf(5) === nothing
end

@testset "validation of all generated modules" begin
    wt = get(ENV, "WASM_TOOLS", "/workspace/tools/wasm-tools-dist/wasm-tools")
    fns = [(x -> x + 1, Tuple{Int64}), ((a, b) -> a * b - a, Tuple{Int64,Int64})]
    for (f, ats) in fns
        comp = compile_wasm(f, ats)
        validate_module(ENGINE, comp.bytes)
        if isfile(wt)
            mktemp() do path, io
                write(io, comp.bytes); close(io)
                @test success(`$wt validate --features all $path`)
            end
        end
    end
end

# --- WasmGC: Julia structs/tuples as GC objects --------------------------------

struct Pt; x::Float64; y::Float64; end
@noinline mkpt(a, b) = Pt(a, b)                 # force materialization
norm2(a, b) = (p = mkpt(a, b); p.x * p.x + p.y * p.y)

mutable struct Counter; n::Int64; end
@noinline bump!(c::Counter, i::Int64) = (c.n += i; nothing)
function count_up(k::Int64)
    c = Counter(0)
    for i in 1:k
        bump!(c, i)
    end
    return c.n
end

struct PairT{T}; a::T; b::T; end
@noinline mkpair(x::T, y::T) where {T} = PairT(x, y)
sumpair(x, y) = (p = mkpair(x, y); p.a + p.b)

@noinline minmax2(a::Int64, b::Int64) = a < b ? (a, b) : (b, a)
spread(a, b) = ((lo, hi) = minmax2(a, b); hi - lo)

mutable struct Node
    val::Int64
    next::Union{Nothing,Node}
end
function buildsum(n::Int64)
    head = nothing
    for i in 1:n
        head = Node(i, head)
    end
    s = 0
    cur = head
    while cur !== nothing
        s += cur.val
        cur = cur.next
    end
    return s
end

struct Packed; a::Int8; b::UInt8; c::Bool; d::Int16; end
@noinline mkpacked(x::Int64) = Packed(x % Int8, x % UInt8, x > 0, x % Int16)
function packsum(x::Int64)
    p = mkpacked(x)
    return Int64(p.a) + Int64(p.b) + (p.c ? 10 : 0) + Int64(p.d)
end

struct Inner; v::Int64; end
struct Outer; i::Inner; w::Float64; end
@noinline mkouter(x::Int64) = Outer(Inner(x), 2.0)
nested_get(x) = mkouter(x).i.v + Int64(round(mkouter(x).w))

@noinline function identity_struct(c::Counter)
    return c
end
mutident(x) = (c = Counter(x); identity_struct(c) === c)

@testset "WasmGC structs" begin
    @difftest norm2 Tuple{Float64,Float64} [(3.0, 4.0), (0.0, 0.0), (-1.5, 2.5)]
    @difftest count_up Tuple{Int64} [(0,), (1,), (10,), (100,)]
    @difftest sumpair Tuple{Int64,Int64} [(3, 4), (-1, 1), (typemax(Int64), 1)]
    @difftest sumpair Tuple{Float64,Float64} [(1.5, 2.5), (NaN, 1.0)]
    @difftest spread Tuple{Int64,Int64} [(3, 9), (9, 3), (5, 5), (-2, 7)]
    @difftest buildsum Tuple{Int64} [(0,), (1,), (10,), (1000,)]
    @difftest packsum Tuple{Int64} [(0,), (1,), (-1,), (127,), (128,), (255,),
                                    (256,), (-129,), (65535,), (123456789,)]
    @difftest nested_get Tuple{Int64} [(5,), (-7,), (0,)]
    @difftest mutident Tuple{Int64} [(3,), (0,)]
end
