# Test eDSL builder approach — scalar ops + control flow + loops

using NativeCodegen
using Test

function run(name, f, argtypes, args, expected)
    print("  $name ... ")
    try
        comp = compile_native(f, argtypes; name=name)
        nf = native_callable_from_so(comp, expected isa Nothing ? Nothing : typeof(expected), argtypes.parameters...)
        r = nf(args...)
        if r == expected
            println("✅ $r")
            rm(comp.so_path)
            return true
        else
            println("❌ got $r, expected $expected")
            rm(comp.so_path)
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
println("\n=== Done ===")
