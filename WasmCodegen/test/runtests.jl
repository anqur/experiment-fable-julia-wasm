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
        # host-resident (externref) arguments pass through as Julia objects
        wire = Any[WasmCodegen.scalar_repr(T) === nothing ? a : WasmCodegen.to_wire(T, a)
                   for (T, a) in zip(argts, args)]
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
            if WasmCodegen.scalar_repr(typeof(nval)) === nothing
                isequal(nval, wval)
            else
                isequal(WasmCodegen.to_wire(typeof(nval), nval), wval) ||
                    isequal(nval, WasmCodegen.from_wire(typeof(nval), wval))
            end
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
    @test !isempty(comp.offloads)
    @test true
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

# --- Memory{T} / Vector as WasmGC arrays ---------------------------------------

function memdirect(n::Int64)
    m = Memory{Int64}(undef, n)
    for i in 1:n; m[i] = 2i; end
    s = 0
    for i in 1:n; s += m[i]; end
    return s + length(m)
end

function sumvec(n::Int64)
    v = Vector{Float64}(undef, n)
    for i in 1:n
        v[i] = i * 0.5
    end
    s = 0.0
    for i in eachindex(v)
        s += v[i]
    end
    return s
end

function bytesum(n::Int64)
    m = Memory{UInt8}(undef, n)
    for i in 1:n; m[i] = (i * 7) % UInt8; end
    s = 0
    for i in n:-1:1; s = s * 3 + m[i]; end
    return s
end

function oob(i::Int64)
    m = Memory{Int64}(undef, 3)
    for k in 1:3; m[k] = k; end
    return m[i]
end

negalloc(n::Int64) = length(Memory{Int64}(undef, n))

function ptmem(n::Int64)
    m = Memory{Pt}(undef, n)
    for i in 1:n; m[i] = Pt(Float64(i), 1.0); end
    s = 0.0
    for i in 1:n; s += m[i].x; end
    return s
end

@testset "Memory and Vector via GC arrays" begin
    @difftest memdirect Tuple{Int64} [(0,), (1,), (10,), (1000,)]
    @difftest sumvec Tuple{Int64} [(0,), (1,), (17,)]
    @difftest bytesum Tuple{Int64} [(0,), (1,), (300,)]
    @difftest oob Tuple{Int64} [(1,), (2,), (3,), (0,), (4,), (-1,), (typemax(Int64),)]
    # note: no 2^40 case — wasm GC arrays are 32-bit-length, native Linux
    # overcommit lets an 8TB Memory "succeed"; an honest platform divergence
    @difftest negalloc Tuple{Int64} [(0,), (5,), (-1,)]
    @difftest ptmem Tuple{Int64} [(0,), (1,), (12,)]
end

# --- host-resident values (externref) across the offload boundary --------------

@noinline tostr(n::Int64) = string(n)              # String result -> externref
@noinline strlen(s::String) = Int64(length(s))     # String param -> externref
roundthrough(n::Int64) = strlen(tostr(n)) + n      # String flows THROUGH wasm

struct Named
    id::Int64
    name::String                                   # externref field in a GC struct
end
@noinline getname(x::Named) = x.name
namedlen(n::Int64) = (nm = Named(n, tostr(n)); strlen(getname(nm)) + nm.id)

@noinline symof(n::Int64) = n > 0 ? :pos : :neg    # Symbol via externref
@noinline symscore(s::Symbol) = s === :pos ? Int64(1) : Int64(-1)
symcode(n::Int64) = symscore(symof(n)) * 2

@testset "externref host values through wasm" begin
    @difftest roundthrough Tuple{Int64} [(0,), (7,), (-123456,), (typemin(Int64),)]
    @difftest namedlen Tuple{Int64} [(5,), (-99,), (10^12,)]
    @difftest symcode Tuple{Int64} [(3,), (-3,), (0,)]
    # entry function with a String (externref) argument called from the host
    comp = compile_wasm(strlen, Tuple{String})
    wf = wasm_callable(strlen, Tuple{String})
    @test wf("hello") == 5
    @test wf("") == 0
end

# --- real Base library functions ------------------------------------------------

basegcd(a::Int64, b::Int64) = gcd(a, b)
basebinom(n::Int64, k::Int64) = binomial(n, k)
baseisqrt(n::Int64) = isqrt(n)
basehash(n::Int64) = reinterpret(Int64, hash(n))
basemod(a::Int64, b::Int64) = mod(a, b)
basefld(a::Int64, b::Int64) = fld(a, b)
basesum(n::Int64) = sum(1:n)
basegen(n::Int64) = sum(i * i for i in 1:n)
basessf(n::Int64) = Int64(searchsortedfirst(1:100, n))
basehypot(a::Float64, b::Float64) = hypot(a, b)
basefloor(x::Float64) = floor(Int64, x)
baseexp(x::Float64) = exp(x)
basesin(x::Float64) = sin(x)
baselog(x::Float64) = log(x)
basestr(n::Int64) = Int64(length(string(n, base=16)))
function basesort(n::Int64)
    v = [((i * 7919) % 100) for i in 1:n]
    sort!(v; alg=InsertionSort)
    issorted(v) ? v[1] + v[end] : -1
end

@testset "Base library functions" begin
    @difftest basegcd Tuple{Int64,Int64} [(12, 18), (0, 0), (typemin(Int64), 0),
                                          (typemin(Int64), typemin(Int64))]
    @difftest basebinom Tuple{Int64,Int64} [(10, 3), (60, 29), (5, 7), (66, 33)]
    @difftest baseisqrt Tuple{Int64} [(0,), (99,), (10^12,), (-1,)]
    @difftest basehash Tuple{Int64} [(0,), (123,), (-1,)]
    @difftest basemod Tuple{Int64,Int64} [(7, 3), (-7, 3), (7, -3), (7, 0)]
    @difftest basefld Tuple{Int64,Int64} [(7, 2), (-7, 2), (typemin(Int64), -1)]
    @difftest basesum Tuple{Int64} [(0,), (100,), (12345,)]
    @difftest basegen Tuple{Int64} [(0,), (10,), (100,)]
    @difftest basessf Tuple{Int64} [(5,), (1000,), (-7,)]
    @difftest basehypot Tuple{Float64,Float64} [(3.0, 4.0), (1e200, 1e200), (0.0, -0.0)]
    @difftest basefloor Tuple{Float64} [(2.7,), (-2.7,), (1e300,), (NaN,)]
    @difftest baseexp Tuple{Float64} [(0.0,), (1.0,), (-2.5,), (710.0,), (NaN,)]
    @difftest basesin Tuple{Float64} [(0.0,), (1.5,), (100.0,), (1e10,)]
    @difftest baselog Tuple{Float64} [(1.0,), (2.5,), (-1.0,), (0.0,)]
    @difftest basestr Tuple{Int64} [(255,), (-16,), (0,)]
    @difftest basesort Tuple{Int64} [(0,), (1,), (50,)]
end

# --- regression tests for audited findings --------------------------------------

@testset "sub-word checked sdiv: typemin ÷ -1 must raise" begin
    divi8(a, b) = a ÷ b
    @difftest divi8 Tuple{Int8,Int8} [(Int8(-128), Int8(-1)), (Int8(-128), Int8(1)),
                                      (Int8(7), Int8(2)), (Int8(7), Int8(0)),
                                      (Int8(-7), Int8(3)), (Int8(127), Int8(-1))]
    divi16(a, b) = a ÷ b
    @difftest divi16 Tuple{Int16,Int16} [(Int16(-32768), Int16(-1)),
                                         (Int16(-32768), Int16(2)),
                                         (Int16(100), Int16(7)), (Int16(1), Int16(0))]
    remi8(a, b) = a % b
    @difftest remi8 Tuple{Int8,Int8} [(Int8(-128), Int8(-1)), (Int8(7), Int8(0)),
                                      (Int8(-7), Int8(3))]
end

@testset "Char raw-bits representation" begin
    charcp(c) = UInt32(c)                      # decodes raw bits -> codepoint
    @difftest charcp Tuple{Char} [('a',), ('λ',), ('∀',), ('\0',), ('\U10FFFF',)]
    charbits(c) = reinterpret(UInt32, c)       # bitcast: identity on raw bits
    @difftest charbits Tuple{Char} [('a',), ('λ',), ('∀',)]
    charid(c) = c                              # round-trip through the wire
    @difftest charid Tuple{Char} [('a',), ('λ',), ('∀',)]
    zextchar(c) = Core.Intrinsics.zext_int(UInt64, c)
    @difftest zextchar Tuple{Char} [('a',), ('λ',)]
    chlt(a, b) = a < b                         # ordering must stay correct
    @difftest chlt Tuple{Char,Char} [('a', 'b'), ('b', 'a'), ('a', 'a'),
                                     ('a', 'λ'), ('λ', 'a'), ('λ', '∀')]
    cheq(a, b) = a == b
    @difftest cheq Tuple{Char,Char} [('a', 'a'), ('a', 'b'), ('∀', '∀')]
    mkchar(x) = Char(x)                        # checked construction from codepoint
    @difftest mkchar Tuple{UInt32} [(UInt32(0x61),), (UInt32(0x3bb),), (UInt32(0x2200),)]
end

# Char crossing the wasm->host offload boundary (from_wire must invert to_wire)
@noinline hostchar(c::Char) = (s = string(c); Int64(codepoint(s[1])))   # offloaded
callhostchar(c::Char) = hostchar(c) + 1

@testset "Char through offloaded host functions" begin
    comp = compile_wasm(callhostchar, Tuple{Char})
    @test !isempty(comp.offloads)
    @difftest callhostchar Tuple{Char} [('a',), ('b',), ('λ',), ('∀',)]
end

@testset "shift counts >= 2^32 on i32-storage values" begin
    shl32(x, n) = x << n
    @difftest shl32 Tuple{Int32,Int64} [(Int32(1), Int64(2)^32), (Int32(1), Int64(2)^32 + 1),
                                        (Int32(1), -(Int64(2)^32)), (Int32(1), Int64(31)),
                                        (Int32(1), Int64(32)), (Int32(1), Int64(0)),
                                        (Int32(-7), Int64(2)^32 + 5)]
    shru8(x, n) = x >> n
    @difftest shru8 Tuple{UInt8,Int64} [(UInt8(0x80), Int64(2)^32 + 1), (UInt8(0x80), Int64(4)),
                                        (UInt8(0xff), Int64(2)^32), (UInt8(0xff), Int64(8))]
    shlu32(x, n) = x << n
    @difftest shlu32 Tuple{UInt32,UInt64} [(UInt32(1), UInt64(2)^32), (UInt32(1), UInt64(1)),
                                           (UInt32(1), UInt64(2)^32 + 31)]
    ashr8big(x, n) = Core.Intrinsics.ashr_int(x, n)
    @difftest ashr8big Tuple{Int8,Int64} [(Int8(-128), Int64(2)^32), (Int8(-128), Int64(1)),
                                          (Int8(-1), Int64(2)^32 + 2)]
end

@testset "signed-interpretation intrinsics on unsigned sub-word reps" begin
    ashru8(x, n) = Core.Intrinsics.ashr_int(x, n)
    @difftest ashru8 Tuple{UInt8,UInt64} [(UInt8(0x80), UInt64(1)), (UInt8(0xff), UInt64(100)),
                                          (UInt8(0x40), UInt64(2)), (UInt8(0x01), UInt64(1))]
    ashru16(x, n) = Core.Intrinsics.ashr_int(x, n)
    @difftest ashru16 Tuple{UInt16,UInt64} [(UInt16(0x8000), UInt64(1)), (UInt16(0xffff), UInt64(50))]
    sltu8(a, b) = Core.Intrinsics.slt_int(a, b)
    @difftest sltu8 Tuple{UInt8,UInt8} [(UInt8(0x80), UInt8(0x01)), (UInt8(0x01), UInt8(0x80)),
                                        (UInt8(0x7f), UInt8(0x80)), (UInt8(0x80), UInt8(0x80))]
    sleu8(a, b) = Core.Intrinsics.sle_int(a, b)
    @difftest sleu8 Tuple{UInt8,UInt8} [(UInt8(0x80), UInt8(0x01)), (UInt8(0x01), UInt8(0x80)),
                                        (UInt8(0x80), UInt8(0x80))]
    sltu16(a, b) = Core.Intrinsics.slt_int(a, b)
    @difftest sltu16 Tuple{UInt16,UInt16} [(UInt16(0x8000), UInt16(0x0001)),
                                           (UInt16(0x0001), UInt16(0x8000))]
    sextu8(x) = Core.Intrinsics.sext_int(Int64, x)
    @difftest sextu8 Tuple{UInt8} [(UInt8(0xff),), (UInt8(0x7f),), (UInt8(0x80),)]
    sextu16(x) = Core.Intrinsics.sext_int(Int32, x)
    @difftest sextu16 Tuple{UInt16} [(UInt16(0xffff),), (UInt16(0x7fff),)]
    sitofpu8(x) = Core.Intrinsics.sitofp(Float64, x)
    @difftest sitofpu8 Tuple{UInt8} [(UInt8(0xff),), (UInt8(0x7f),), (UInt8(0x80),)]
    sitofpu16(x) = Core.Intrinsics.sitofp(Float64, x)
    @difftest sitofpu16 Tuple{UInt16} [(UInt16(0xffff),), (UInt16(0x0001),)]
    # signed reps must be unaffected (control)
    ashri8(x, n) = Core.Intrinsics.ashr_int(x, n)
    @difftest ashri8 Tuple{Int8,UInt64} [(Int8(-128), UInt64(1)), (Int8(64), UInt64(2))]
    slti8(a, b) = Core.Intrinsics.slt_int(a, b)
    @difftest slti8 Tuple{Int8,Int8} [(Int8(-1), Int8(1)), (Int8(1), Int8(-1))]
end

@testset "Bool results are normalized to {0,1}" begin
    truncb(x) = Core.Intrinsics.trunc_int(Bool, x)
    @difftest truncb Tuple{Int64} [(6,), (2,), (3,), (1,), (0,), (-1,)]
    # bad Bools used to flip branches *inside* wasm (no wire decoding involved)
    truncb_branch(x) = Core.Intrinsics.trunc_int(Bool, x) ? Int64(1) : Int64(2)
    @difftest truncb_branch Tuple{Int64} [(6,), (3,), (0,)]
    addb(a, b) = Core.Intrinsics.add_int(a, b)        # 1-bit wrap: true+true == false
    @difftest addb Tuple{Bool,Bool} [(true, true), (true, false), (false, false)]
    addb_branch(a, b) = Core.Intrinsics.add_int(a, b) ? Int64(10) : Int64(20)
    @difftest addb_branch Tuple{Bool,Bool} [(true, true), (true, false), (false, false)]
    zextb(x) = Core.Intrinsics.zext_int(Int64, Core.Intrinsics.trunc_int(Bool, x))
    @difftest zextb Tuple{Int64} [(6,), (3,), (1,), (0,)]
    modb(x) = x % Bool                                # control: and_int path
    @difftest modb Tuple{Int64} [(6,), (3,), (0,)]
end

mutable struct CF
    const a::Int64
    b::Int64
end
setconst(x::Int64) = (c = CF(1, 2); setfield!(c, :a, x); getfield(c, :a))
setnonconst(x::Int64) = (c = CF(1, 2); setfield!(c, :b, x); getfield(c, :b))

@testset "setfield! on const fields traps like native throws" begin
    @difftest setconst Tuple{Int64} [(5,), (1,)]      # native ErrorException ~ wasm trap
    @difftest setnonconst Tuple{Int64} [(5,), (-3,)]  # plain fields still writable
end

mutable struct NodeQ
    v::Int64
end
pickref(c, x, y) = Core.ifelse(c, NodeQ(x), NodeQ(y)).v

@testset "Core.ifelse on GC refs uses typed select" begin
    comp = compile_wasm(pickref, Tuple{Bool,Int64,Int64})
    validate_module(ENGINE, comp.bytes)               # used to fail validation
    @difftest pickref Tuple{Bool,Int64,Int64} [(true, 1, 2), (false, 1, 2)]
end

@noinline mkpair_noinline(x, y) = PairT(x, y)
retpair(a::Int64, b::Int64) = mkpair_noinline(a, b)
takepair(p::PairT{Int64}) = p.a + p.b

@testset "GC-typed entry signatures raise CompileError (not a process abort)" begin
    # wrapping such an export would abort the process inside wasmtime's
    # wasm_valtype_kind; the compiler must refuse loudly instead
    @test_throws CompileError compile_wasm(retpair, Tuple{Int64,Int64})
    @test_throws CompileError compile_wasm(takepair, Tuple{PairT{Int64}})
    err = try compile_wasm(retpair, Tuple{Int64,Int64}); nothing catch e; e end
    @test err isa CompileError && occursin("boundary", err.msg)
end

@testset "muladd documented latitude: fused or unfused, never anything else" begin
    mm(a, b, c) = muladd(a, b, c)
    wf = wasm_callable(mm, Tuple{Float64,Float64,Float64})
    for (a, b, c) in [(1 + 2.0^-52, 1 + 2.0^-52, -(1 + 2.0^-51)),
                      (2.0, 3.0, 1.0), (0.1, 0.2, 0.3),
                      (1e308, 10.0, -Inf), (NaN, 1.0, 1.0)]
        w = wf(a, b, c)
        @test isequal(w, a * b + c) || isequal(w, fma(a, b, c))
    end
    mm32(a, b, c) = muladd(a, b, c)
    wf32 = wasm_callable(mm32, Tuple{Float32,Float32,Float32})
    for (a, b, c) in [(1 + Float32(2.0)^-23, 1 + Float32(2.0)^-23, -(1 + Float32(2.0)^-22)),
                      (2.0f0, 3.0f0, 1.0f0)]
        w = wf32(a, b, c)
        @test isequal(w, a * b + c) || isequal(w, fma(a, b, c))
    end
end

@testset "unsafe_trunc documented latitude: wasm saturates deterministically" begin
    ut64(x) = unsafe_trunc(Int64, x)
    wf = wasm_callable(ut64, Tuple{Float64})
    @test wf(1.9) === Int64(1) && wf(-2.9) === Int64(-2)      # in-range: exact
    @test wf(NaN) === Int64(0)                                # wasm trunc_sat
    @test wf(1e300) === typemax(Int64)
    @test wf(-1e300) === typemin(Int64)
    utu64(x) = unsafe_trunc(UInt64, x)
    wfu = wasm_callable(utu64, Tuple{Float64})
    @test wfu(3.7) === Int64(3)        # wire repr of UInt64(3)
    @test wfu(NaN) === Int64(0)
    @test wfu(-1.5) === Int64(0)
    ut8(x) = unsafe_trunc(Int8, x)
    wf8 = wasm_callable(ut8, Tuple{Float64})
    @test wf8(7.9) === Int32(7)        # wire repr of Int8(7)
    @test wf8(1e12) === Int32(-1)      # saturated at i32 width, then wrapped
    # defined-behavior conversions must match native exactly (errors and all)
    chk64(x) = Int64(x)
    @difftest chk64 Tuple{Float64} [(3.0,), (3.5,), (NaN,), (1e300,), (-0.0,)]
    rnd64(x) = round(Int64, x)
    @difftest rnd64 Tuple{Float64} [(2.5,), (-2.5,), (NaN,), (1e300,), (0.49,)]
    trc64(x) = trunc(Int64, x)
    @difftest trc64 Tuple{Float64} [(2.9,), (-2.9,), (NaN,), (1e300,)]
end

# --- try/catch/finally via wasm exception handling ------------------------------

function safediv(a::Int64, b::Int64)
    try
        return a ÷ b
    catch
        return Int64(-999)
    end
end
function nested_try(n::Int64)
    acc = 0
    for i in 1:n
        try
            acc += i == 3 ? error("three") : i
        catch
            acc += 100
        end
    end
    return acc
end
function finallyfn(n::Int64)
    acc = 0
    try
        acc = n * 2
        n > 5 && throw(ArgumentError("big"))
        acc += 1
    finally
        acc += 1000
    end
    return acc
end
function safeidx(i::Int64)
    m = Memory{Int64}(undef, 3)
    for k in 1:3; m[k] = 10k; end
    try
        return m[i]
    catch
        return Int64(-1)
    end
end
function tryphi(n::Int64)
    local x
    try
        x = n > 0 ? n * 2 : error("neg")
        x += 1
    catch
        x = -n
    end
    return x
end

@testset "try/catch via wasm-EH" begin
    @difftest safediv Tuple{Int64,Int64} [(7, 2), (7, 0), (typemin(Int64), -1), (0, 5)]
    @difftest nested_try Tuple{Int64} [(0,), (2,), (5,), (10,)]
    @difftest finallyfn Tuple{Int64} [(1,), (5,), (10,)]
    @difftest safeidx Tuple{Int64} [(1,), (3,), (0,), (99,), (typemin(Int64),)]
    @difftest tryphi Tuple{Int64} [(5,), (-3,), (0,)]
end

# --- overlay interpreter: string primitives, parse, dynamic vectors -------------

strbytes(s::String) = (c = 0; for i in 1:ncodeunits(s); c += codeunit(s, i); end; c)
parseback(n::Int64) = parse(Int64, string(n)) + 1
tryp(s::String) = (x = tryparse(Int64, s); x === nothing ? Int64(-1) : x)
function growsum(n::Int64)
    v = Int64[]
    for i in 1:n
        push!(v, i * i)
    end
    s = 0
    for x in v
        s += x
    end
    return s + length(v)
end
function copyvec(n::Int64)
    v = collect(1:n)
    w = copy(v)
    w[1] = -1
    return v[1] * 1000 + w[1]
end
strlen2(s::String) = Int64(length(s))   # UTF-8 decoding loop over codeunits

@testset "overlay interpreter (strings, parse, growth)" begin
    @difftest strbytes Tuple{String} [("hello",), ("",), ("α β γ",)]
    @difftest parseback Tuple{Int64} [(41,), (-1000,), (0,)]
    @difftest tryp Tuple{String} [("123",), ("abc",), ("-99",), ("",)]
    @difftest growsum Tuple{Int64} [(0,), (1,), (100,), (1000,)]
    @difftest copyvec Tuple{Int64} [(1,), (5,)]
    @difftest strlen2 Tuple{String} [("hello",), ("αβγ",), ("",)]
end
