s = :foo
println("isbitstype=", isbitstype(typeof(s)), " ismutable=", ismutable(typeof(s)))
p = pointer_from_objref(s)
println("pointer_from_objref(:foo) = ", p)
GC.@preserve s begin
    bp = reinterpret(Ptr{UInt8}, p)
    println("bytes from pointer_from_objref (offset 0..23):")
    row = ""
    for off in 0:23
        b = unsafe_load(bp, off + 1)
        row *= string(b; base=16, pad=2) * " "
        (off + 1) % 8 == 0 && (println("  +", off - 7, "..+", off, ": ", row); row = "")
    end
    println("  remaining: ", row)
end
println(":foo name bytes = ", UInt8.(codeunits("foo")))
