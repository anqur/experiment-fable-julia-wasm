# Trace the memoryref tracking to debug :not_atomic issue
# Usage: julia +nightly --project=. NativeCodegen/test/debug_trace_memref.jl

using NativeCodegen: NCGInterp

function ar_inb_get(a::Vector{Int64},i::Int64)
    @inbounds r = a[i]
    return r
end

interp = NCGInterp()
tt = Base.signature_type(ar_inb_get, Tuple{Vector{Int64}, Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, _ = result[1]

# Trace each statement that involves MemoryRef
for (i, stmt) in enumerate(ir.stmts)
    e = stmt[:stmt]
    if e isa Expr && e.head == :call
        f = e.args[1]
        if f isa Core.GlobalRef
            fn = f.name
            if fn == :memoryrefnew || fn == :memoryrefget || fn == :memoryrefset! || fn == :getfield
                println("  [$i] $(fn):")
                for (j, a) in enumerate(e.args)
                    println("       arg$j: $(a) :: $(typeof(a))")
                    if a isa Core.SSAValue
                        println("         -> SSA type: $(ir.stmts[a.id][:type])")
                    elseif a isa Core.Argument
                        println("         -> arg type: $(ir.argtypes[a.n])")
                    end
                end
                println()
            end
        end
    end
end
