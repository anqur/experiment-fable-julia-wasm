using NativeCodegen
using NativeCodegen: NCGInterp

function dump_ir(f, argtypes, label)
    println("\n========== ", label, " ==========")
    interp = NCGInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]
    println("rettype: ", rt)
    for (i, s) in enumerate(ir.stmts)
        println("%", i, " :: ", s[:type], "  ", s[:stmt])
    end
end

p1(a::Vector{Int64}, x::Int64) = push!(a, x)
rz(a::Vector{Int64}, n::Int64) = resize!(a, n)
ap(a::Vector{Int64}, b::Vector{Int64}) = append!(a, b)
buildpush(n::Int64) = (a = Int64[]; for i in 1:n; push!(a, i); end; a)
shrink(a::Vector{Int64}) = (resize!(a, 2); a)

dump_ir(p1, Tuple{Vector{Int64},Int64}, "push!(a,x)")
dump_ir(rz, Tuple{Vector{Int64},Int64}, "resize!(a,n)")
dump_ir(ap, Tuple{Vector{Int64},Vector{Int64}}, "append!(a,b)")
dump_ir(buildpush, Tuple{Int64}, "buildpush loop")
dump_ir(shrink, Tuple{Vector{Int64}}, "resize! shrink + return a")
