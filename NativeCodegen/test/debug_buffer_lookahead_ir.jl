using NativeCodegen
using NativeCodegen: NCGInterp, compile_native, CompileError
import JuliaSyntax
import JuliaSyntax.Tokenize: next_token
import JuliaSyntax: ParseStream

const JLexer = JuliaSyntax.Tokenize.Lexer{IOBuffer}

function dump_ir(f, argtypes, label)
    println("--- ", label, " ---")
    interp = NCGInterp()
    tt = Base.signature_type(f, argtypes)
    m = Base._methods_by_ftype(tt, -1, interp.world)
    isempty(m) && (println("  (no method found)"); return)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rt = r[1]
    println("  rettype: ", rt)
    println("  nargs: ", length(ir.argtypes))
    for (i, s) in enumerate(ir.stmts)
        println("  %", i, " :: ", s[:type], "  ", s[:stmt])
    end
    return ir, rt
end

interp = NCGInterp()

println("\n========== __lookahead_index overlay IR ==========")
dump_ir(JuliaSyntax.__lookahead_index, Tuple{ParseStream, Int, Bool}, "__lookahead_index(ParseStream, Int, Bool)")

println("\n========== _buffer_lookahead_tokens (reprise, for callee analysis) ==========")
tt = Base.signature_type(JuliaSyntax._buffer_lookahead_tokens, Tuple{JLexer, Vector{JuliaSyntax.SyntaxToken}})
m = Base._methods_by_ftype(tt, -1, interp.world)
if !isempty(m)
    mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
    ir_buf, rt_buf = dump_ir(JuliaSyntax._buffer_lookahead_tokens, Tuple{JLexer, Vector{JuliaSyntax.SyntaxToken}}, "_buffer_lookahead_tokens")
    println("\n--- Callees from _buffer_lookahead_tokens overlay IR ---")
    for (i, s) in enumerate(ir_buf.stmts)
        stmt = s[:stmt]
        if stmt isa Expr && stmt.head === :invoke
            mi_inner = stmt.args[1]
            println("  %", i, " invoke: ", mi_inner.def.method.name, " specTypes=", mi_inner.def.specTypes)
        end
    end
end

println("\n========== next_token(lexer, start=true) callees ==========")
ir_tok, _ = dump_ir(next_token, Tuple{JLexer, Bool}, "next_token")
println("\n--- Callees from next_token overlay IR ---")
for (i, s) in enumerate(ir_tok.stmts)
    stmt = s[:stmt]
    if stmt isa Expr && stmt.head === :invoke
        mi_inner = stmt.args[1]
        println("  %", i, " invoke: ", mi_inner.def.method.name, " specTypes=", mi_inner.def.specTypes)
    end
end

println("\n========== _next_token overlay IR for '1' input ==========")
# _next_token(lexer, char) is called when there's no string state
# Let's check what _next_token does for various chars
dump_ir(JuliaSyntax.Tokenize._next_token, Tuple{JLexer, Char}, "_next_token(Lexer{IOBuffer}, Char)")
