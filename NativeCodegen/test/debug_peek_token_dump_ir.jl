# debug_peek_token_dump_ir.jl — Dump IR for peek_token to see what's being compiled
using NativeCodegen
import Base.JuliaSyntax as JS

println("=== Dumping IR for peek_token ===")

# Get the IR for peek_token(ParseStream, Int)
methods_list = collect(methods(JS.peek_token))
m = methods_list[findfirst(x -> x.sig == Tuple{typeof(JS.peek_token), JS.ParseStream, Integer}, methods_list)]
println("Method: ", m)

try
    for (src, code_ir) in Base.code_ircode(m)
        println("\n=== Source ===")
        println(src)

        println("\n=== CFG ===")
        println(code_ir.code)

        println("\n=== First 20 statements ===")
        for (i, stmt) in enumerate(code_ir.code.stmts[1:min(20, end)])
            println("  $i: $stmt  (type: $(code_ir.code.ssavaluetypes[i]))")
        end

        break  # Just first version
    end
catch e
    println("Error: ", e)
end
