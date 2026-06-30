using NativeCodegen

sz1(a::Vector{Int64}) = size(a, 1)
len1(a::Vector{Int64}) = length(a)

# Fresh array filled by a computed loop (no literal-tuple source).
function squares()::Vector{Int64}
    a = Vector{Int64}(undef, 5)
    for i in 1:5
        a[i] = i * i
    end
    return a
end

# Sum of a passed-in array (loop read).
function asum(a::Vector{Int64})
    s = 0
    for i in 1:length(a)
        s += a[i]
    end
    return s
end

for (name, f, rt, at, args, exp) in [
        ("size(a,1)", sz1, Int64, Tuple{Vector{Int64}}, (Int64[10,20,30],), 3),
        ("length(a)", len1, Int64, Tuple{Vector{Int64}}, (Int64[10,20,30],), 3),
        ("squares", squares, Vector{Int64}, Tuple{}, (), [1,4,9,16,25]),
        ("asum", asum, Int64, Tuple{Vector{Int64}}, (Int64[1,2,3,4],), 10),
    ]
    try
        r = compile_and_call(f, rt, at, args...)
        ok = r == exp
        println("$(ok ? "✅" : "❌") $name → $r")
    catch e
        println("❌ $name ERR: $e")
    end
end
