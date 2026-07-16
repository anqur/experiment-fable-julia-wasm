using NativeCodegen: WasmInterp
import Base.JuliaSyntax as JS

interp = WasmInterp()

function dump_full(f, argtypes, label)
    println("\n===== ", label, " :: ", argtypes, " =====")
    tt = Base.signature_type(f, argtypes)
    ms = Base._methods_by_ftype(tt, -1, interp.world)
    isempty(ms) && (println("  (no method)"); return)
    mi = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    isempty(r) && (println("  (no ircode)"); return)
    ir, rt = r[1]
    println("rettype: ", rt)
    for (i, s) in enumerate(ir.stmts)
        println("  %", i, " :: ", s[:type], "  ", s[:stmt])
    end
end

# bump has several arities; dump the most-used ones.
for AT in (Tuple{JS.ParseStream, JS.Kind},
           Tuple{JS.ParseStream, JS.Kind, Int},
           Tuple{JS.ParseStream, JS.Kind, Int, Bool})
    isdefined(JS, :bump) && dump_full(JS.bump, AT, "bump$AT")
end
isdefined(JS, :bump_trivia) && dump_full(JS.bump_trivia, Tuple{JS.ParseStream}, "bump_trivia")
