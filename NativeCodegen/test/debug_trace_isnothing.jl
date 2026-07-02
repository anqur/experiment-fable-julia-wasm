using JuliaSyntax: JuliaSyntax
using NativeCodegen

# Patch emit_icmp to print debug info
import NativeCodegen.builder_emit: emit_icmp, resolve_operand, BuilderCtx, NOTHING_TAG

# Monkey-patch emit_icmp for debugging
original_emit_icmp = emit_icmp
Core.eval(NativeCodegen.builder_emit, quote
    function emit_icmp(bc::BuilderCtx, cond::UInt32, args, ir)
        println("=== emit_icmp called ===")
        println("  cond: ", cond)
        println("  args: ", args)
        lhs = resolve_operand(bc, args[1], ir)
        rhs = resolve_operand(bc, args[2], ir)
        println("  lhs_id: ", lhs, " rhs_id: ", rhs)
        println("  NOTHING_TAG: ", NOTHING_TAG)
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, cond, lhs, rhs)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, TYPE_I32)
    end
end)

tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = 1")
leaf = JuliaSyntax.children(tree)[3]
gntype = typeof(tree)

println("=== Testing is_leaf ===\n")
f(n::gntype) = JuliaSyntax.children(n) === nothing
try
    result = compile_and_call(f, Bool, Tuple{gntype}, leaf; name="debug_isnothing")
    println("Result: $result, expected: true")
catch e
    println("ERROR: $(typeof(e)): $e")
end
