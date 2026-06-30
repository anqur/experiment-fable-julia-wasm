using NativeCodegen

add2(a::Int64, b::Int64) = a + b
muladd2(a::Int64, b::Int64) = a * b + 7
f2(a::Float64, b::Float64) = a + b

mutable struct MBox
    v::Int64
end
setget2(b::MBox, k::Int64) = (b.v = b.v + k; b.v)

for (name, f, rt, at, args, exp) in [
        ("add2", add2, Int64, Tuple{Int64,Int64}, (3,4), 7),
        ("muladd2", muladd2, Int64, Tuple{Int64,Int64}, (5,6), 37),
        ("f2", f2, Float64, Tuple{Float64,Float64}, (1.5,2.5), 4.0),
        ("setget2", setget2, Int64, Tuple{MBox,Int64}, (MBox(10), 5), 15),
    ]
    try
        r = compile_and_call(f, rt, at, args...)
        ok = r == exp
        println("$(ok ? "✅" : "❌") $name → $r (expected $exp)")
    catch e
        println("❌ $name ERR: $e")
    end
end
