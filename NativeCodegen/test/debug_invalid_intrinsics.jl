import Base: Intrinsics
import Core: IntrinsicFunction

# Build a reverse lookup: IntrinsicFunction => name Symbol
lut = IdDict{IntrinsicFunction, Symbol}()
for nm in names(Intrinsics; all=true)
    nm === :Intrinsics && continue
    try
        f = getfield(Intrinsics, nm)
        f isa IntrinsicFunction || continue
        if !haskey(lut, f)
            lut[f] = nm
        end
    catch
    end
end
println("lookup table size: ", length(lut))

# Verify identity + name resolution for the raw Core.Intrinsics.and_int
f = Intrinsics.and_int
println("and_int identity name: ", get(lut, f, :MISSING))
println("add_int identity name: ", get(lut, Intrinsics.add_int, :MISSING))
println("trunc_int identity name: ", get(lut, Intrinsics.trunc_int, :MISSING))
println("checked_udiv_int name: ", get(lut, Intrinsics.checked_udiv_int, :MISSING))

# Now use a raw Core.Intrinsics.and_int in code, lower it, check the IR callee
# resolves through the table.
raw_and(a::UInt, b::UInt) = (Core.Intrinsics.and_int)(a, b)
ir, rt = only(Base.code_ircode(raw_and, (UInt, UInt)))
println("\nIR of raw and_int:")
for s in ir.stmts
    println("  ", s[:stmt])
end
for s in ir.stmts
    st = s[:stmt]
    if st isa Expr && st.head == :call && st.args[1] isa IntrinsicFunction
        callee = st.args[1]
        println("\nIR callee === Core.Intrinsics.and_int? ", callee === Intrinsics.and_int)
        println("table resolves to: ", get(lut, callee, :MISSING))
    end
end
