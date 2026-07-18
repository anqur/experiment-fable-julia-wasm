using NativeCodegen: CC, NCGInterp
import Base.JuliaSyntax as JS
const INTERP = NCGInterp()

f = JS._buffer_lookahead_tokens
tt = Base.signature_type(f, Tuple{Any, Any})
ms = Base._methods_by_ftype(tt, -1, INTERP.world)
mi = CC.specialize_method(ms[1].method, tt, Core.svec())
ir, ret = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)[1]

# Get the stmt for index 64
s64 = ir.stmts[64].data.stmt[64]
println("stmt 64 type: ", typeof(s64))
if isa(s64, Expr)
    println("  head: ", s64.head)
    println("  args[0]: ", typeof(s64.args[1]))
    println("  args[0]: ", repr(s64.args[1]))
    if isa(s64.args[1], Core.GlobalRef)
        println("  GlobalRef: mod=$(s64.args[1].mod), name=$(s64.args[1].name)")
    elseif isa(s64.args[1], Core.SSAValue)
        println("  SSAValue: id=$(s64.args[1].id)")
    elseif isa(s64.args[1], QuoteNode)
        println("  QuoteNode: value=$(s64.args[1].value)")
    elseif isa(s64.args[1], Core.Const)
        println("  Const: val=$(s64.args[1].val) type=$(typeof(s64.args[1].val))")
    else
        println("  OTHER: ", typeof(s64.args[1]))
    end
    println("  args: ", length(s64.args))
    for i in 2:length(s64.args)
        a = s64.args[i]
        println("  arg[$i]: type=$(typeof(a)) val=$(repr(a))")
    end
elseif isa(s64, Core.PhiNode)
    println("  PhiNode")
elseif isa(s64, Core.GotoNode)
    println("  GotoNode: label=$(s64.label)")
elseif isa(s64, Core.GotoIfNot)
    println("  GotoIfNot: cond=$(s64.cond) dest=$(s64.dest)")
elseif isa(s64, Core.PiNode)
    println("  PiNode")
elseif isa(s64, Core.ReturnNode)
    println("  ReturnNode")
else
    println("  type: ", typeof(s64))
end

# Also print stmts 61-67
stmts_arr = ir.stmts[1].data.stmt
for i in 61:67
    s = stmts_arr[i]
    if s === nothing
        println("stmt $i: nothing")
    elseif isa(s, Expr)
        println("stmt $i ($(s.head)): ", s)
    else
        println("stmt $i: ", repr(s))
    end
end
