using NativeCodegen: CC, WasmInterp
import Base.JuliaSyntax as JS
const INTERP = WasmInterp()

# Find parse_float_literal signature
ms = methods(JS.parse_float_literal)
println("methods(parse_float_literal):")
for m in ms
    println("  ", m.sig)
end

# Try each signature
for m in ms
    tt = m.sig
    global mm = Base._methods_by_ftype(tt, -1, INTERP.world)
    if isempty(mm); continue; end
    try
        local mi = CC.specialize_method(mm[1].method, tt, Core.svec())
        local res = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
        if isempty(res); continue; end
        local ir, ret = res[1]
        println("\n=== sig: ", tt, " ===")
        for (i, s) in enumerate(ir.stmts)
            local st = s[:stmt]
            if st isa Expr && (st.head == :foreigncall || (st.head == :call && length(st.args)>0 && string(st.args[1]) in ("strtof","strtod")))
                println("si=$i type=$(s[:type]) :: ", repr(st))
            end
        end
    catch e
        println("  err for $tt: ", typeof(e), " ", e)
    end
end
