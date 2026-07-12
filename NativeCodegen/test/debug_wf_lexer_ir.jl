using NativeCodegen: CC, WasmInterp
import Base.JuliaSyntax as JS

const INTERP = WasmInterp()

# Find the Lexer method the codegen sees. It reads an IOBuffer.
f = JS.Tokenize.Lexer
println("Lexer methods:")
for m in methods(f)
    println("  ", m.sig)
end

# The dump arg accesses look like IOBuffer fields (:data@0, :readable@9, :size@16, :ptr@32, :offset@40).
# Try the IOBuffer signature.
for argt in (Base.IOBuffer,)
    global tt = Base.signature_type(f, Tuple{argt})
    global matches = Base._methods_by_ftype(tt, -1, INTERP.world)
    if matches === nothing || isempty(matches)
        println("no match for $argt"); continue
    end
    global mi = CC.specialize_method(matches[1].method, tt, Core.svec())
    println("\n=== Lexer($argt)  specTypes=$(mi.specTypes) ===")
    global result = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
    global ir, rettype = result[1]
    println("argtypes: ", ir.argtypes)
    println("rettype: ", rettype, "  nstmts=", length(ir.stmts))
    for si in 1:length(ir.stmts)
        println("[", si, "] type=", ir.stmts[si][:type], " :: ", repr(ir.stmts[si][:stmt]))
    end
end
