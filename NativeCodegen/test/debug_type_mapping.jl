using NativeCodegen
import JuliaSyntax

# Patch icmp to add debug
const orig_icmp = NativeCodegen.emit_icmp
function debug_icmp(bc::NativeCodegen.BuilderCtx, cond::UInt32, args, ir)
    sym = cond == 0 ? "EQ" :
          cond == 1 ? "NE" :
          cond == 2 ? "SLT" :
          cond == 3 ? "SLE" : "??"
    println("DEBUG emit_icmp($sym): args[1]=$(repr(args[1])) type=$(typeof(args[1]))")
    println("  args[2]=$(repr(args[2])) type=$(typeof(args[2]))")
    lhs_t = NativeCodegen.get_operand_type(args[1], ir)
    rhs_t = NativeCodegen.get_operand_type(args[2], ir)
    lhs_t = lhs_t isa Core.Const ? lhs_t.val : lhs_t
    rhs_t = rhs_t isa Core.Const ? rhs_t.val : rhs_t
    println("  lhs_type=$lhs_t rhs_type=$rhs_t")
    try
        println("  ct_lhs=$(NativeCodegen.cranelift_type(lhs_t)) ct_rhs=$(NativeCodegen.cranelift_type(rhs_t))")
    catch e
        println("  ct_lhs/rhs error: $e")
    end

    # Check if harmonize does anything
    lhs_id = NativeCodegen.resolve_operand(bc, args[1], ir)
    rhs_id = NativeCodegen.resolve_operand(bc, args[2], ir)
    lhs_id2 = NativeCodegen._harmonize_binop_type(bc, lhs_id, args[1], rhs_id, args[2], ir)
    rhs_id2 = NativeCodegen._harmonize_binop_type(bc, rhs_id, args[2], lhs_id, args[1], ir)
    if lhs_id != lhs_id2
        println("  LHS HARMONIZED: $lhs_id -> $lhs_id2")
    end
    if rhs_id != rhs_id2
        println("  RHS HARMONIZED: $rhs_id -> $rhs_id2")
    end

    result = orig_icmp(bc, cond, args, ir)
    println("  result=$result")
    return result
end

# Test with literal (works)
function test_literal(t::JuliaSyntax.GreenNode)
    h = JuliaSyntax.head(t)
    k = reinterpret(UInt16, h.kind)
    return k == UInt16(3)
end

# Test with global const (fails)
const K_GLOBAL = UInt16(3)
function test_const(t::JuliaSyntax.GreenNode)
    h = JuliaSyntax.head(t)
    k = reinterpret(UInt16, h.kind)
    return k == K_GLOBAL
end

tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = a + b * c + 1")
T = typeof(tree)

# Monkey-patch for the test
# We need to override emit_icmp inside NativeCodegen
println("=== Test literal ===")
try
    comp = NativeCodegen.compile_native(test_literal, Tuple{T}; name="tl")
    println("OK")
catch e
    println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
end

println("\n=== Test const ===")
try
    comp = NativeCodegen.compile_native(test_const, Tuple{T}; name="tc")
    println("OK")
catch e
    println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
end
