using NativeCodegen
using NativeCodegen: WasmInterp, compile_native, CompileError
import JuliaSyntax

function dump_ir(f, argtypes, label)
    println("--- ", label, " ---")
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    isempty(m) && (println("  (no method found)"); return)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]
    println("  rettype: ", rt)
    for (i, s) in enumerate(ir.stmts)
        println("  %", i, " :: ", s[:type], "  ", s[:stmt])
    end
    return ir, rt
end

function try_compile(f, argtypes, label)
    print("  compile: ")
    try
        comp = compile_native(f, argtypes; name="jsx")
        rm(comp.so_path)
        println("✅ ok")
    catch e
        if e isa InterruptException; rethrow(); end
        msg = sprint(showerror, e)
        # Truncate long messages
        println("❌ ", typeof(e).name.name, ": ", length(msg) > 120 ? msg[1:120]*"..." : msg)
    end
end

# ===== Simple predicates (Bool return) =====
println("\n========== has_flags ==========")
ir1, rt1 = dump_ir(JuliaSyntax.has_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "has_flags")
try_compile(JuliaSyntax.has_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "has_flags")

println("\n========== is_number ==========")
ir2, rt2 = dump_ir(JuliaSyntax.is_number, Tuple{JuliaSyntax.Kind}, "is_number")
try_compile(JuliaSyntax.is_number, Tuple{JuliaSyntax.Kind}, "is_number")

println("\n========== is_leaf ==========")
ir3, rt3 = dump_ir(JuliaSyntax.is_leaf, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "is_leaf")
try_compile(JuliaSyntax.is_leaf, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "is_leaf")

# ===== Kind construction =====
println("\n========== Kind(x::Integer) ==========")
ir4, rt4 = dump_ir(JuliaSyntax.Kind, Tuple{Int}, "Kind(Int)")
try_compile(JuliaSyntax.Kind, Tuple{Int}, "Kind(Int)")

# ===== call_type_flags =====
println("\n========== call_type_flags ==========")
ir5, rt5 = dump_ir(JuliaSyntax.call_type_flags, Tuple{JuliaSyntax.RawFlags}, "call_type_flags")
try_compile(JuliaSyntax.call_type_flags, Tuple{JuliaSyntax.RawFlags}, "call_type_flags")
