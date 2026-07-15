# debug_peek_token_ir.jl — Examine IR for peek_token to understand the crash
using NativeCodegen
import Base.JuliaSyntax as JS

println("=== Examining peek_token IR ===")

# Get the ParseStream method for peek_token with n argument
m_list = methods(JS.peek_token)
parsestream_method = nothing
for m in m_list
    sig = m.sig
    # Find the ParseStream version with n argument
    if sig == Tuple{typeof(JS.peek_token), JS.ParseStream, Integer}
        parsestream_method = m
        break
    end
end

if parsestream_method === nothing
    # Try the default version (no n argument)
    for m in m_list
        sig = m.sig
        if sig == Tuple{typeof(JS.peek_token), JS.ParseStream}
            parsestream_method = m
            break
        end
    end
end

if parsestream_method !== nothing
    println("Method: ", parsestream_method)
    println("Signature: ", parsestream_method.sig)

    # Get IR for peek_token
    println("\n=== IR for peek_token ===")
    try
        for (src, code_ir) in Base.code_ircode(parsestream_method)
            println("Source:")
            println(src)
            println("\nIRCode statements:")
            for (i, stmt) in enumerate(code_ir.code.stmts)
                println("  $i: $stmt")
            end
            println("\nSSA value types:")
            for (i, t) in enumerate(code_ir.code.ssavaluetypes)
                println("  SSA $i: $t")
            end
            break  # Just first version
        end
    catch e
        println("Error getting IR: ", e)
    end
else
    println("Could not find ParseStream peek_token method")
end
