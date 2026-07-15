# debug_compile_peek_token_dump.jl — Compile peek_token and dump Cranelift IR
using NativeCodegen
import Base.JuliaSyntax as JS

println("=== Compiling peek_token with Cranelift IR dump ===")

# Test function that calls peek_token
f_pt1(s::JS.ParseStream) = begin
    tok = JS.peek_token(s, 1)
    return Int64(reinterpret(UInt32, tok.head))
end

ps = JS.ParseStream("1 + 2")

# Set up dump directory
dump_dir = "/tmp/native_ir_dump"
mkpath(dump_dir)

# Compile with dump
try
    withenv("NATIVE_BUILDER_DUMP_DIR" => dump_dir) do
        comp = compile_native(f_pt1, Tuple{JS.ParseStream}; name="peek_token_k1")
        println("Compilation succeeded!")
        println("Check IR dumps in: $dump_dir")
    end
catch e
    println("Error during compilation: ", e)
end
