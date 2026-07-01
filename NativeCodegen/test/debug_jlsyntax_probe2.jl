using NativeCodegen
using NativeCodegen: WasmInterp, compile_native, CompileError
import JuliaSyntax

# ===== Helpers =====
function dump_ir(f, argtypes, label)
    println("=== ", label, " ===")
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    if isempty(m)
        println("  rettype: ?")
        println("  (no method found)")
        return nothing, nothing
    end
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
        comp = compile_native(f, argtypes; name="jls2")
        rm(comp.so_path)
        println("ok")
    catch e
        if e isa InterruptException; rethrow(); end
        msg = sprint(showerror, e)
        # Truncate long messages past 200 chars
        println("ERROR: ", typeof(e).name.name, ": ", length(msg) > 200 ? msg[1:200]*"..." : msg)
    end
end

# ===== 1. numeric_flags(RawFlags) =====
# Int((f >> 8) % UInt8)
println("\n"^2, "="^70)
println(">>> 1. JuliaSyntax.numeric_flags(RawFlags)")
println(">>> Source: Int((f >> 8) % UInt8)")
dump_ir(JuliaSyntax.numeric_flags, Tuple{JuliaSyntax.RawFlags}, "numeric_flags(RawFlags)")
try_compile(JuliaSyntax.numeric_flags, Tuple{JuliaSyntax.RawFlags}, "numeric_flags(RawFlags)")

# ===== 2. remove_flags(RawFlags, RawFlags, RawFlags) =====
# RawFlags(n & ~(RawFlags((|)(fs...))))
println("\n"^2, "="^70)
println(">>> 2. JuliaSyntax.remove_flags(RawFlags, RawFlags...)")
println(">>> Source: RawFlags(n & ~(RawFlags((|)(fs...))))")
dump_ir(JuliaSyntax.remove_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "remove_flags(3args)")
try_compile(JuliaSyntax.remove_flags, Tuple{JuliaSyntax.RawFlags, JuliaSyntax.RawFlags, JuliaSyntax.RawFlags}, "remove_flags(3args)")

# ===== 3. is_keyword(Kind) =====
# K"BEGIN_KEYWORDS" <= k <= K"END_KEYWORDS"
println("\n"^2, "="^70)
println(">>> 3. JuliaSyntax.is_keyword(Kind)")
println(">>> Source: BEGIN_KEYWORDS <= k <= END_KEYWORDS  (chained comparison)")
dump_ir(JuliaSyntax.is_keyword, Tuple{JuliaSyntax.Kind}, "is_keyword(Kind)")
try_compile(JuliaSyntax.is_keyword, Tuple{JuliaSyntax.Kind}, "is_keyword(Kind)")

# ===== 4. kind(Kind) =====
# identity: kind(k::Kind) = k
println("\n"^2, "="^70)
println(">>> 4. JuliaSyntax.kind(Kind)")
println(">>> Source: kind(k::Kind) = k  (identity)")
dump_ir(JuliaSyntax.kind, Tuple{JuliaSyntax.Kind}, "kind(Kind)")
try_compile(JuliaSyntax.kind, Tuple{JuliaSyntax.Kind}, "kind(Kind)")

# ===== 5. kind(SyntaxHead) =====
# field access: kind(head::SyntaxHead) = head.kind
println("\n"^2, "="^70)
println(">>> 5. JuliaSyntax.kind(SyntaxHead)")
println(">>> Source: kind(head::SyntaxHead) = head.kind  (field access)")
dump_ir(JuliaSyntax.kind, Tuple{JuliaSyntax.SyntaxHead}, "kind(SyntaxHead)")
try_compile(JuliaSyntax.kind, Tuple{JuliaSyntax.SyntaxHead}, "kind(SyntaxHead)")

# ===== 6. flags(SyntaxHead) =====
# field access: flags(head::SyntaxHead) = head.flags
println("\n"^2, "="^70)
println(">>> 6. JuliaSyntax.flags(SyntaxHead)")
println(">>> Source: flags(head::SyntaxHead) = head.flags  (field access)")
dump_ir(JuliaSyntax.flags, Tuple{JuliaSyntax.SyntaxHead}, "flags(SyntaxHead)")
try_compile(JuliaSyntax.flags, Tuple{JuliaSyntax.SyntaxHead}, "flags(SyntaxHead)")

# ===== 7. is_trivia(SyntaxHead) =====
# has_flags(x, TRIVIA_FLAG)  where has_flags = (flags & test_flags) != 0
println("\n"^2, "="^70)
println(">>> 7. JuliaSyntax.is_trivia(SyntaxHead)")
println(">>> Source: has_flags(x, TRIVIA_FLAG) = (flags(x) & TRIVIA_FLAG) != 0")
dump_ir(JuliaSyntax.is_trivia, Tuple{JuliaSyntax.SyntaxHead}, "is_trivia(SyntaxHead)")
try_compile(JuliaSyntax.is_trivia, Tuple{JuliaSyntax.SyntaxHead}, "is_trivia(SyntaxHead)")

# ===== 8. numchildren(GreenNode) =====
# isnothing(node.children) ? 0 : length(node.children)
println("\n"^2, "="^70)
println(">>> 8. JuliaSyntax.numchildren(GreenNode{SyntaxHead})")
println(">>> Source: isnothing(node.children) ? 0 : length(node.children)")
dump_ir(JuliaSyntax.numchildren, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "numchildren(GreenNode)")
try_compile(JuliaSyntax.numchildren, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "numchildren(GreenNode)")

# ===== 9. span(GreenNode) =====
# field access: span(node::GreenNode) = node.span  (returns UInt32)
println("\n"^2, "="^70)
println(">>> 9. JuliaSyntax.span(GreenNode{SyntaxHead})")
println(">>> Source: span(node::GreenNode) = node.span  (UInt32 field)")
dump_ir(JuliaSyntax.span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "span(GreenNode)")
try_compile(JuliaSyntax.span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}, "span(GreenNode)")

# ===== 10. child_position_span(GreenNode, Int, Int) =====
# Loop with span arithmetic + chained children access
println("\n"^2, "="^70)
println(">>> 10. JuliaSyntax.child_position_span(GreenNode, Int, Int)")
println(">>> Source: loop over path, children, span sums, return tuple")
dump_ir(JuliaSyntax.child_position_span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}, Int, Int}, "child_position_span")
try_compile(JuliaSyntax.child_position_span, Tuple{JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}, Int, Int}, "child_position_span")

# ===== 11. _copy_normalize_number!(Ptr{UInt8}, Ptr{UInt8}, Int) =====
# Byte-level loop with unsafe_load/unsafe_store!, pointer arithmetic
println("\n"^2, "="^70)
println(">>> 11. JuliaSyntax._copy_normalize_number!(Ptr{UInt8}, Ptr{UInt8}, Int)")
println(">>> Source: byte-level while loop, pointer arithmetic, unsafe_load/store")
dump_ir(JuliaSyntax._copy_normalize_number!, Tuple{Ptr{UInt8}, Ptr{UInt8}, Int}, "_copy_normalize_number!")
try_compile(JuliaSyntax._copy_normalize_number!, Tuple{Ptr{UInt8}, Ptr{UInt8}, Int}, "_copy_normalize_number!")

println("\n"^2, "="^70)
println("DONE")
