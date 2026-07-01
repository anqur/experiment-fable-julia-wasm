# Test eDSL builder approach — scalar ops + control flow + loops

using NativeCodegen
using Test

# Unified test runner. `use_cc` selects compile_and_call (for GC-object returns);
# otherwise uses compile_native + native_callable_from_so.
function run(name, f, argtypes, args, expected; use_cc=false)
    print("  $name ... ")
    try
        r = if use_cc
            compile_and_call(f, expected isa Nothing ? Nothing : typeof(expected), argtypes, args...)
        else
            comp = compile_native(f, argtypes; name=name)
            nf = native_callable_from_so(comp, expected isa Nothing ? Nothing : typeof(expected), argtypes.parameters...)
            result = nf(args...)
            rm(comp.so_path)
            result
        end
        if r == expected
            println("✅ $r")
            return true
        else
            println("❌ got $r, expected $expected")
            return false
        end
    catch e
        println("❌ $e")
        return false
    end
end

println("=== Arithmetic ===")
a64_add(a::Int64,b::Int64)=a+b ; run("add64",a64_add,Tuple{Int64,Int64},(Int64(5),Int64(3)),8)
a64_sub(a::Int64,b::Int64)=a-b ; run("sub64",a64_sub,Tuple{Int64,Int64},(Int64(10),Int64(3)),7)
a64_mul(a::Int64,b::Int64)=a*b ; run("mul64",a64_mul,Tuple{Int64,Int64},(Int64(4),Int64(7)),28)
a64_ret()=42 ; run("ret42",a64_ret,Tuple{},(),42)

println("\n=== Comparisons ===")
eq_t(a::Int64,b::Int64)=a==b ; run("eqT",eq_t,Tuple{Int64,Int64},(Int64(5),Int64(5)),true)
eq_f(a::Int64,b::Int64)=a==b ; run("eqF",eq_f,Tuple{Int64,Int64},(Int64(5),Int64(3)),false)

println("\n=== Float ===")
f_add(a::Float64,b::Float64)=a+b ; run("fadd",f_add,Tuple{Float64,Float64},(1.5,2.5),4.0)

println("\n=== Control Flow ===")
cf_max(a::Int64,b::Int64)=a>b ? a : b ; run("max53",cf_max,Tuple{Int64,Int64},(Int64(5),Int64(3)),5)
cf_max2(a::Int64,b::Int64)=a>b ? a : b ; run("max35",cf_max2,Tuple{Int64,Int64},(Int64(3),Int64(5)),5)
cf_pos(a::Int64)=a>0 ? a : 0 ; run("pos5",cf_pos,Tuple{Int64},(Int64(5),),5)
cf_neg(a::Int64)=a>0 ? a : 0 ; run("neg3",cf_neg,Tuple{Int64},(Int64(-3),),0)

println("\n=== Loops ===")
lp_cnt(n::Int64)=(while n>0;n=n-1 end;n) ; run("cd5",lp_cnt,Tuple{Int64},(Int64(5),),0)
lp_cnt0(n::Int64)=(while n>0;n=n-1 end;n) ; run("cd0",lp_cnt0,Tuple{Int64},(Int64(0),),0)
lp_gcd(a::Int64,b::Int64)=(while b!=0;a,b=b,a%b end;a) ; run("gcd",lp_gcd,Tuple{Int64,Int64},(Int64(12),Int64(8)),4)
lp_gcd2(a::Int64,b::Int64)=(while b!=0;a,b=b,a%b end;a) ; run("gcd2",lp_gcd2,Tuple{Int64,Int64},(Int64(7),Int64(13)),1)

println("\n=== Strings ===")
st_len(s::String)=Base.ncodeunits(s) ; run("ncu5",st_len,Tuple{String},("hello",),5)
st_codeunit(s::String)=Base.codeunit(s,Int64(1)) ; run("cu_h",st_codeunit,Tuple{String},("hello",),UInt8('h'))
st_codeunit2(s::String)=Base.codeunit(s,Int64(5)) ; run("cu_o",st_codeunit2,Tuple{String},("hello",),UInt8('o'))
st_sizeof(s::String)=Core.sizeof(s) ; run("sizeof5",st_sizeof,Tuple{String},("hello",),5)
st_isempty(s::String)=Base.isempty(s) ; run("iespF",st_isempty,Tuple{String},("hello",),false)
st_isempty2(s::String)=Base.isempty(s) ; run("iespT",st_isempty2,Tuple{String},("",),true)

println("\n=== Structs ===")
mutable struct Point
    x::Int64
    y::Int64
end
sf_get_x(p::Point)=p.x       ; run("getx",sf_get_x,Tuple{Point},(Point(42,99),),42)
sf_get_y(p::Point)=p.y       ; run("gety",sf_get_y,Tuple{Point},(Point(42,99),),99)
sf_fluent(p::Point,v::Int64)=(p.x=v; p.y=v; p.x+p.y) ; run("setadd",sf_fluent,Tuple{Point,Int64},(Point(0,0),Int64(3)),6)
mutable struct Wrapper ; val::Point ; end
sf_nested(w::Wrapper)=w.val.x + w.val.y ; run("nested",sf_nested,Tuple{Wrapper},(Wrapper(Point(10,20)),),30)

println("\n=== Arrays ===")
ar_len(a::Vector{Int64})=length(a) ; run("alen4",ar_len,Tuple{Vector{Int64}},(Int64[10,20,30,40],),4)
ar_get(a::Vector{Int64},i::Int64)=(p=pointer(a); unsafe_load(p,i)) ; run("aget",ar_get,Tuple{Vector{Int64},Int64},(Int64[10,20,30,40],Int64(3)),30)
ar_set(a::Vector{Int64},v::Int64)=(p=pointer(a); unsafe_store!(p,v,Int64(1)); unsafe_load(p,Int64(1))) ; run("aset",ar_set,Tuple{Vector{Int64},Int64},(Int64[0,0,0,0],Int64(99)),99)
ar_inb_get(a::Vector{Int64},i::Int64)=(@inbounds r=a[i]; r) ; run("inb2",ar_inb_get,Tuple{Vector{Int64},Int64},(Int64[10,20,30,40],Int64(2)),20)

println("\n=== Object Return ===")
# Mutable struct allocation + return to Julia (mutable structs compare by
# identity, so check fields explicitly rather than via the generic `run`).
mkpoint()::Point = Point(42, 99)
print("  mkpoint ... ")
try
    comp = compile_native(mkpoint, Tuple{}; name="mkpoint")
    r = native_callable_from_so(comp, Point)()
    ok = r isa Point && r.x == 42 && r.y == 99
    println("$(ok ? "✅" : "❌") Point($(r.x), $(r.y))")
    rm(comp.so_path)
catch e
    println("❌ $e")
end
# Multi-element tuple return (value equality, so `run` works).
mktuple() = (7, 8) ; run("mktuple", mktuple, Tuple{}, (), (7, 8))

println("\n=== Array Return ===")
# Fresh array allocation + return — a *real* Julia array via jl_alloc_array_1d.
mkarray()::Vector{Int64} = Int64[1, 2, 3, 4] ; run("mkarr", mkarray, Tuple{}, (), [1, 2, 3, 4])
# Computed fill (loop writing i*i) + return — exercises the loop CFG + allocator.
function mksquares()::Vector{Int64}
    a = Vector{Int64}(undef, 5)
    for i in 1:5; a[i] = i * i; end
    a
end
run("squares", mksquares, Tuple{}, (), [1, 4, 9, 16, 25])
# arraysize intrinsic on a passed-in array.
ar_size(a::Vector{Int64}) = size(a, 1) ; run("arsz3", ar_size, Tuple{Vector{Int64}}, (Int64[10,20,30],), 3)

println("\n=== Strings (concat/return) ===")
# String concatenation (a*b → invoke Base._string; literal-literal → invoke *).
sc_cat2(a::String,b::String) = a * b ; run("scat2", sc_cat2, Tuple{String,String}, ("foo","bar"), "foobar"; use_cc=true)
# 3-way concat via left-fold (2 args + literal).
sc_cat3(a::String,b::String) = a * b * "!" ; run("scat3", sc_cat3, Tuple{String,String}, ("ab","cd"), "abcd!"; use_cc=true)
# String literal return.
sc_mkstr() = "hello" ; run("smkstr", sc_mkstr, Tuple{}, (), "hello"; use_cc=true)
# Literal-literal concat (inference may constant-fold; both paths handled).
sc_greet() = "Hello, " * "World!" ; run("sgreet", sc_greet, Tuple{}, (), "Hello, World!"; use_cc=true)

println("\n=== Array Growth (resize!) ===")
# resize! shrink: [1,2,3,4] -> [1,2].
ag_shrink(a::Vector{Int64}) = (resize!(a, 2); a) ; run("ashrk", ag_shrink, Tuple{Vector{Int64}}, (Int64[1,2,3,4],), [1,2]; use_cc=true)
# Build an array dynamically by growing + filling (the headline growth case).
function ag_build(n::Int64)::Vector{Int64}
    a = Vector{Int64}(undef, 0)
    for i in 1:n; resize!(a, i); a[i] = i*i; end
    a
end
run("abuild", ag_build, Tuple{Int64}, (5,), [1,4,9,16,25]; use_cc=true)
# resize! grow: length grows, original elements preserved (new slots are undef,
# so check length + first elements explicitly rather than full-array equality).
ag_grow(a::Vector{Int64}, n::Int64) = (resize!(a, n); a)
print("  agrow ... ")
try
    global ag_grow
    r = compile_and_call(ag_grow, Vector{Int64}, Tuple{Vector{Int64},Int64}, Int64[1,2], 4)
    ok = length(r) == 4 && r[1] == 1 && r[2] == 2
    println("$(ok ? "✅" : "❌") length=$(length(r)) first_two=[$(r[1]),$(r[2])]")
catch e
    println("❌ $e")
end

println("\n=== push! ===")
# push! mutates in place: [1,2] + push!(9) → length 3, last element 9.
pushone(a::Vector{Int64}, x::Int64) = (push!(a, x); a)
run("pushone", pushone, Tuple{Vector{Int64},Int64}, (Int64[1,2], Int64(9)), [1,2,9]; use_cc=true)
# Build by pushing in a loop: empty alloc + grow loop + return.
function buildpush(n::Int64)::Vector{Int64}
    a = Int64[]
    for i in 1:n; push!(a, i*i); end
    a
end
run("bldpush", buildpush, Tuple{Int64}, (5,), [1,4,9,16,25]; use_cc=true)

println("\n=== pop! ===")
# pop! returns the last element AND mutates the caller's array in place.
# Both must be checked — use direct compile_and_call (not run's equality form).
popone(a::Vector{Int64}) = pop!(a)
print("  popone ... ")
try
    global popone
    a = Int64[10,20,30]
    r = compile_and_call(popone, Int64, Tuple{Vector{Int64}}, a)
    ok = (r == 30 && length(a) == 2 && a == [10,20])
    println("$(ok ? "✅" : "❌") r=$r (want 30), a after=$a (want [10,20])")
catch e
    println("❌ $e")
end
# pop! in a loop: sum the popped elements; array is emptied. (2-arg ptr+i64 → Int64.)
function popsum(a::Vector{Int64}, k::Int64)
    s = 0
    for i in 1:k; s += pop!(a); end
    s
end
print("  popsum ... ")
try
    global popsum
    a = Int64[1,2,3,4]
    r = compile_and_call(popsum, Int64, Tuple{Vector{Int64},Int64}, a, 4)
    ok = (r == 10 && isempty(a))
    println("$(ok ? "✅" : "❌") r=$r (want 10), a after=$a (want Int64[])")
catch e
    println("❌ $e")
end

println("\n=== append! ===")
# append! mutates the destination in place and returns it.
appendsrc(a::Vector{Int64}, b::Vector{Int64}) = (append!(a, b); a)
run("appendsrc", appendsrc, Tuple{Vector{Int64},Vector{Int64}}, (Int64[1,2,3], Int64[4,5]), [1,2,3,4,5]; use_cc=true)
# append! in a loop with real growth (2-arg ptr+ptr → Vector).
function appendloop(a::Vector{Int64}, b::Vector{Int64})::Vector{Int64}
    for i in 1:3; append!(a, b); end
    a
end
run("appendloop", appendloop, Tuple{Vector{Int64},Vector{Int64}}, (Int64[0], Int64[1,2]), [0,1,2,1,2,1,2]; use_cc=true)

println("\n=== Conversions (int <-> float) ===")
cv_sitofp(x::Int64)::Float64 = Float64(x) ; run("sitofp", cv_sitofp, Tuple{Int64}, (Int64(5),), 5.0)
cv_uitofp(x::UInt64)::Float64 = Float64(x) ; run("uitofp", cv_uitofp, Tuple{UInt64}, (UInt64(7),), 7.0)
cv_fptosi(x::Float64)::Int64 = unsafe_trunc(Int64, x) ; run("fptosi", cv_fptosi, Tuple{Float64}, (3.7,), 3)
cv_fptoui(x::Float64)::UInt64 = unsafe_trunc(UInt64, x) ; run("fptoui", cv_fptoui, Tuple{Float64}, (3.7,), UInt64(3))
cv_fpext(x::Float32)::Float64 = Float64(x) ; run("fpext", cv_fpext, Tuple{Float32}, (1.5f0,), 1.5)
# fptrunc via Float64-returning roundtrip (bridge float path returns Float64):
cv_fptrunc(x::Float64)::Float64 = Float64(Float32(x)) ; run("fptrunc", cv_fptrunc, Tuple{Float64}, (1.9,), Float64(Float32(1.9)))
# sext_int on sub-word (exercises the emit_convert arg-order fix).
cv_sext(x::Int8)::Int64 = Int64(x) ; run("sext_i8", cv_sext, Tuple{Int8}, (Int8(-5),), -5)

println("\n=== Float math ===")
fm_sqrt(x::Float64)::Float64 = sqrt(x) ; run("sqrt", fm_sqrt, Tuple{Float64}, (2.0,), sqrt(2.0))
fm_ceil(x::Float64)::Float64 = ceil(x) ; run("ceil", fm_ceil, Tuple{Float64}, (2.3,), 3.0)
fm_floor(x::Float64)::Float64 = floor(x) ; run("floor", fm_floor, Tuple{Float64}, (2.7,), 2.0)
fm_trunc(x::Float64)::Float64 = trunc(x) ; run("truncf", fm_trunc, Tuple{Float64}, (2.7,), 2.0)
fm_abs(x::Float64)::Float64 = abs(x) ; run("fabs", fm_abs, Tuple{Float64}, (-2.5,), 2.5)
fm_copysign(x::Float64, y::Float64)::Float64 = copysign(x, y) ; run("copysign", fm_copysign, Tuple{Float64,Float64}, (2.0, -1.0), -2.0)

println("\n=== Bit ops (full-width; sub-word needs renormalization, see CLAUDE.md) ===")
bo_ctlz(x::UInt64)::UInt64 = leading_zeros(x) ; run("ctlz", bo_ctlz, Tuple{UInt64}, (UInt64(1),), UInt64(63))
bo_cttz(x::UInt64)::UInt64 = trailing_zeros(x) ; run("cttz", bo_cttz, Tuple{UInt64}, (UInt64(2),), UInt64(1))
bo_ctpop(x::UInt64)::UInt64 = count_ones(x) ; run("ctpop", bo_ctpop, Tuple{UInt64}, (UInt64(0xFF),), UInt64(8))
bo_bswap(x::UInt64)::UInt64 = bswap(x) ; run("bswap", bo_bswap, Tuple{UInt64}, (UInt64(0x12345678),), bswap(UInt64(0x12345678)))
bo_flipsign(x::Int64, y::Int64)::Int64 = flipsign(x, y) ; run("flipsign", bo_flipsign, Tuple{Int64,Int64}, (Int64(3), Int64(-1)), -3)
bo_abs(x::Int64)::Int64 = abs(x) ; run("absi", bo_abs, Tuple{Int64}, (Int64(-5),), 5)

println("\n=== Checked arithmetic (overflow pairs) ===")
# checked_{s,u}{add,sub,mul}_int return (value, overflowed::Bool) — a single IR
# stmt materialized into two value ids, read via getfield(pair, 1/2). Tested
# differentially against the native Julia intrinsic itself (the ground truth),
# across overflow boundaries, the signed-mul typemin*-1 trap-guard case, and the
# mul a==0 branch. NB: the compiled functions call the RAW intrinsic directly —
# Base.Checked.* does not inline under our overlay interpreter, so only the raw
# form reaches the eDSL (the form real post-inlining code uses).
TM, TX = typemin(Int64), typemax(Int64)
UX = typemax(UInt64)

# Compile-once, multi-case runner; expected comes from the native oracle.
function run_checked(name, f, argtypes, inputs, oracle)
    print("  $name ... ")
    try
        retT = typeof(oracle(inputs[1]...))
        comp = compile_native(f, argtypes; name=name)
        nf = native_callable_from_so(comp, retT, argtypes.parameters...)
        ok = true
        for args in inputs
            got, exp = nf(args...), oracle(args...)
            got != exp && (println("\n    ❌ args=$args got $got, expected $exp"); ok = false)
        end
        println(ok ? "✅ ($(length(inputs)) cases)" : "  ❌")
        rm(comp.so_path)
        return ok
    catch e
        println("❌ $e")
        return false
    end
end

function csadd_v(a::Int64, b::Int64); r,_ = Core.Intrinsics.checked_sadd_int(a,b); r; end
function csadd_f(a::Int64, b::Int64); r,f = Core.Intrinsics.checked_sadd_int(a,b); f; end
run_checked("csadd_v", csadd_v, Tuple{Int64,Int64},
    [(Int64(5),Int64(3)), (TX,Int64(1)), (TM,Int64(-1)), (TX,TX), (Int64(-5),Int64(-3))],
    (a,b)->first(Core.Intrinsics.checked_sadd_int(a,b)))
run_checked("csadd_f", csadd_f, Tuple{Int64,Int64},
    [(Int64(5),Int64(3)), (TX,Int64(1)), (TM,Int64(-1)), (TX,TX), (Int64(10),Int64(-10))],
    (a,b)->last(Core.Intrinsics.checked_sadd_int(a,b)))

function cssub_v(a::Int64, b::Int64); r,_ = Core.Intrinsics.checked_ssub_int(a,b); r; end
function cssub_f(a::Int64, b::Int64); r,f = Core.Intrinsics.checked_ssub_int(a,b); f; end
run_checked("cssub_v", cssub_v, Tuple{Int64,Int64},
    [(Int64(10),Int64(3)), (TM,Int64(1)), (TX,Int64(-1))],
    (a,b)->first(Core.Intrinsics.checked_ssub_int(a,b)))
run_checked("cssub_f", cssub_f, Tuple{Int64,Int64},
    [(Int64(10),Int64(3)), (TM,Int64(1)), (TX,Int64(-1)), (Int64(0),Int64(-1))],
    (a,b)->last(Core.Intrinsics.checked_ssub_int(a,b)))

function csmul_v(a::Int64, b::Int64); r,_ = Core.Intrinsics.checked_smul_int(a,b); r; end
function csmul_f(a::Int64, b::Int64); r,f = Core.Intrinsics.checked_smul_int(a,b); f; end
run_checked("csmul_v", csmul_v, Tuple{Int64,Int64},
    [(Int64(6),Int64(7)), (TM,Int64(-1)), (TX,Int64(2)), (TM,Int64(1)), (Int64(-3),Int64(4))],
    (a,b)->first(Core.Intrinsics.checked_smul_int(a,b)))
run_checked("csmul_f", csmul_f, Tuple{Int64,Int64},
    [(Int64(6),Int64(7)), (TM,Int64(-1)), (TX,Int64(2)), (TM,Int64(1)),
     (Int64(0),Int64(12345)), (Int64(-1),Int64(5)), (Int64(-1),TM)],
    (a,b)->last(Core.Intrinsics.checked_smul_int(a,b)))

function cuadd_f(a::UInt64, b::UInt64); r,f = Core.Intrinsics.checked_uadd_int(a,b); f; end
function cusub_f(a::UInt64, b::UInt64); r,f = Core.Intrinsics.checked_usub_int(a,b); f; end
function cumul_v(a::UInt64, b::UInt64); r,_ = Core.Intrinsics.checked_umul_int(a,b); r; end
function cumul_f(a::UInt64, b::UInt64); r,f = Core.Intrinsics.checked_umul_int(a,b); f; end
run_checked("cuadd_f", cuadd_f, Tuple{UInt64,UInt64},
    [(UInt64(1),UInt64(2)), (UX,UInt64(1)), (UX,UX), (UInt64(0),UInt64(0))],
    (a,b)->last(Core.Intrinsics.checked_uadd_int(a,b)))
run_checked("cusub_f", cusub_f, Tuple{UInt64,UInt64},
    [(UInt64(5),UInt64(3)), (UInt64(0),UInt64(1)), (UInt64(3),UInt64(5))],
    (a,b)->last(Core.Intrinsics.checked_usub_int(a,b)))
run_checked("cumul_v", cumul_v, Tuple{UInt64,UInt64},
    [(UInt64(3),UInt64(4)), (UX,UInt64(2)), (UInt64(0),UInt64(7)), (UX,UX)],
    (a,b)->first(Core.Intrinsics.checked_umul_int(a,b)))
run_checked("cumul_f", cumul_f, Tuple{UInt64,UInt64},
    [(UInt64(3),UInt64(4)), (UX,UInt64(2)), (UInt64(0),UInt64(7)), (UX,UX)],
    (a,b)->last(Core.Intrinsics.checked_umul_int(a,b)))

println("\n=== N-arg (3+ args via generated _gcall dispatcher) ===")
# 3× Int64 → Int64
add3(a::Int64, b::Int64, c::Int64)::Int64 = a + b + c ; run("add3", add3, Tuple{Int64,Int64,Int64}, (1,2,3), 6)
fma3(a::Int64, b::Int64, c::Int64)::Int64 = a + b * c ; run("fma3", fma3, Tuple{Int64,Int64,Int64}, (Int64(10),Int64(3),Int64(4)), 22)
# 3× Int64 → Bool
between3(x::Int64, lo::Int64, hi::Int64)::Bool = (lo <= x) && (x <= hi)
run("between3T", between3, Tuple{Int64,Int64,Int64}, (5,1,10), true)
run("between3F", between3, Tuple{Int64,Int64,Int64}, (15,1,10), false)
# control flow at N=3
myclamp(x::Int64, lo::Int64, hi::Int64)::Int64 = x < lo ? lo : (x > hi ? hi : x)
run("clamp_lo", myclamp, Tuple{Int64,Int64,Int64}, (Int64(-1),Int64(0),Int64(10)), 0)
run("clamp_hi", myclamp, Tuple{Int64,Int64,Int64}, (Int64(99),Int64(0),Int64(10)), 10)
run("clamp_mid", myclamp, Tuple{Int64,Int64,Int64}, (Int64(5),Int64(0),Int64(10)), 5)
# 4× Int64 → Int64
add4(a::Int64, b::Int64, c::Int64, d::Int64)::Int64 = a + b + c + d ; run("add4", add4, Tuple{Int64,Int64,Int64,Int64}, (1,2,3,4), 10)
# ptr + 3× Int64 → Int64 (mixes pointer and scalar args at N=4)
mix4(a::Vector{Int64}, x::Int64, y::Int64, z::Int64)::Int64 = length(a) + x + y + z
run("mix4", mix4, Tuple{Vector{Int64},Int64,Int64,Int64}, (Int64[10,20], 1, 2, 3), 8; use_cc=true)
# 3× Float32 → Float32 (Float32 ABI must hold at N=3)
fma3f(a::Float32, b::Float32, c::Float32)::Float32 = a + b * c ; run("fma3f", fma3f, Tuple{Float32,Float32,Float32}, (Float32(1),Float32(2),Float32(3)), 7.0f0)
# ptr return at N=3: construct a 3-tuple from 3 Int64 args
maketri(x::Int64, y::Int64, z::Int64)::Tuple{Int64,Int64,Int64} = (x, y, z)
run("maketri", maketri, Tuple{Int64,Int64,Int64}, (1,2,3), (1,2,3); use_cc=true)
# 8× Int64 → Int64 (exercises the generated dispatcher well past the old 2-arg ceiling)
add8(a::Int64, b::Int64, c::Int64, d::Int64, e::Int64, f::Int64, g::Int64, h::Int64)::Int64 = a + b + c + d + e + f + g + h
run("add8", add8, Tuple{Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64},
    (Int64(1),Int64(2),Int64(3),Int64(4),Int64(5),Int64(6),Int64(7),Int64(8)), 36)

println("\n=== Runtime-element array literals ([a,b,c] with variables) ===")
lit2(a::Int64, b::Int64)::Vector{Int64} = [a, b]
run("lit2", lit2, Tuple{Int64,Int64}, (Int64(3),Int64(4)), [3,4]; use_cc=true)
lit3(a::Int64, b::Int64, c::Int64)::Vector{Int64} = [a, b, c]
run("lit3", lit3, Tuple{Int64,Int64,Int64}, (Int64(1),Int64(2),Int64(3)), [1,2,3]; use_cc=true)
# same variable thrice in a 1-arg literal
lit_dup(i::Int64)::Vector{Int64} = [i, i, i]
run("litdup", lit_dup, Tuple{Int64}, (Int64(7),), [7,7,7]; use_cc=true)
# Float64 element type
litf(a::Float64, b::Float64)::Vector{Float64} = [a, b]
run("litf", litf, Tuple{Float64,Float64}, (Float64(1.5),Float64(2.5)), [1.5,2.5]; use_cc=true)
# restore the appendloop test using the dynamic literal that originally hit the bug
function appendloop_dyn(n::Int64)::Vector{Int64}
    a = Int64[]
    for i in 1:n; append!(a, [i, i+1]); end
    a
end
print("  appendloop_dyn ... ")
try
    global appendloop_dyn
    r = compile_and_call(appendloop_dyn, Vector{Int64}, Tuple{Int64}, Int64(3))
    println(r == [1,2,2,3,3,4] ? "✅ $r" : "❌ $r (want [1,2,2,3,3,4])")
catch e
    println("❌ $e")
end

println("\n=== Done ===")
