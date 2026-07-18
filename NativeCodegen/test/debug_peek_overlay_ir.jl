# debug_peek_overlay_ir.jl — Use the NativeCodegen overlay to get optimized IR for peek_token
using NativeCodegen
import Base.JuliaSyntax as JS
using Core.Compiler

println("=== Getting optimized IR for peek_token ===")

# Use the NativeCodegen overlay interpreter
overlay = NativeCodegen.NCGInterp()

# Get the method instance for peek_token(ParseStream, Int)
sig = Tuple{typeof(JS.peek_token), JS.ParseStream, Int}
mi = Core.Compiler.specialize_method(Tuple{Callable, JS.ParseStream, Int}, Tuple{typeof(JS.peek_token), JS.ParseStream, Int}, #=sgetfield=#JuliaSyntax.peek_token)

println("MethodInstance: ", mi)

try
    # Get IR code through the overlay
    result = Core.Compiler.InferenceResult(mi, overlay)
    Core.Compiler.typeinf_edge!(overlay, result)
    ir = Core.Compiler.IRCode(result)
    println("\n=== Optimized IR ===")
    println(ir)
catch e
    println("Error getting IR: ", e)
    println("Stack trace:")
    for (i, line) in enumerate(stacktrace(catch_backtrace()))
        println("  $i: $line")
    end
end
