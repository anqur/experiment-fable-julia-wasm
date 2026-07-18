# Probe2: Broader JuliaSyntax compilation coverage
# Tests: varargs, loops, recursion, string/array construction, pointer ops, continue
using NativeCodegen
using NativeCodegen: NCGInterp, CompileError
import Base.JuliaSyntax as JuliaSyntax

function dump_ir(f, argtypes, label)
    println("--- ", label, " ---")
    interp = NCGInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    isempty(m) && (println("  (no method found)"); return nothing, nothing)
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
        comp = compile_native(f, argtypes; name=label)
        rm(comp.so_path)
        println("✅ ok")
        return true
    catch e
        if e isa InterruptException; rethrow(); end
        msg = sprint(showerror, e)
        println("❌ ", typeof(e).name.name, ": ", length(msg) > 150 ? msg[1:150]*"..." : msg)
        return false
    end
end

# ===== 1. remove_flags: varargs + bitwise fold =====
println("\n========== remove_flags (varargs) ==========")
ir1, _ = dump_ir(JuliaSyntax.remove_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "remove_flags(flags, a, b)")
try_compile(JuliaSyntax.remove_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "remove_flags")

# ===== 2. child_position_span: varargs + nested for loops =====
println("\n========== child_position_span (varargs + nested loops) ==========")
ir2, _ = dump_ir(JuliaSyntax.child_position_span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}, Int, Int}, "child_position_span(node, 1, 2)")
try_compile(JuliaSyntax.child_position_span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}, Int, Int}, "child_position_span")

# ===== 3. _first_error: recursion + Union{Nothing,T} =====
println("\n========== _first_error (recursion) ==========")
ir3, _ = dump_ir(JuliaSyntax._first_error, Tuple{JuliaSyntax.SyntaxNode}, "_first_error(node)")
try_compile(JuliaSyntax._first_error, Tuple{JuliaSyntax.SyntaxNode}, "_first_error")

# ===== 4. unescape_raw_string: nested loops + byte array I/O =====
println("\n========== unescape_raw_string (nested loops + IO) ==========")
ir4, _ = dump_ir(JuliaSyntax.unescape_raw_string, Tuple{IOBuffer, Vector{UInt8}, Int, Int, Bool}, "unescape_raw_string")
try_compile(JuliaSyntax.unescape_raw_string, Tuple{IOBuffer, Vector{UInt8}, Int, Int, Bool}, "unescape_raw_string")

# ===== 5. parse_int_literal: string replace + Union returns =====
println("\n========== parse_int_literal (string alloc + Union) ==========")
ir5, _ = dump_ir(JuliaSyntax.parse_int_literal, Tuple{String}, "parse_int_literal(str)")
try_compile(JuliaSyntax.parse_int_literal, Tuple{String}, "parse_int_literal")

# ===== 6. parse_float_literal: Union signature + conditional alloc =====
println("\n========== parse_float_literal (Union sig + cond alloc) ==========")
ir6, _ = dump_ir(JuliaSyntax.parse_float_literal, Tuple{Type{Float64}, String, Int, Int}, "parse_float_literal")
try_compile(JuliaSyntax.parse_float_literal, Tuple{Type{Float64}, String, Int, Int}, "parse_float_literal")

# ===== 7. _copy_normalize_number!: pointer ops + continue =====
println("\n========== _copy_normalize_number! (pointer + continue) ==========")
ir7, _ = dump_ir(JuliaSyntax._copy_normalize_number!, Tuple{Ptr{UInt8}, Ptr{UInt8}, Int}, "_copy_normalize_number!")
try_compile(JuliaSyntax._copy_normalize_number!, Tuple{Ptr{UInt8}, Ptr{UInt8}, Int}, "_copy_normalize_number!")

println("\n=== Done ===")
