# Test actual CLIF compilation

using NativeCodegen

println("=== Testing Actual CLIF Compilation ===")

# Test 1: Single block function
clif_single_block = """
function %test_single(i64) -> i64 {
block0(v0: i64):
    v1 = iconst.i64 1
    v2 = iadd v0, v1
    return v2
}
"""

println("Test 1: Compiling single block CLIF")
try
    comp = NativeCodegen.compile_clif_from_string(clif_single_block)
    println("✓ Single block compiled successfully!")
catch e
    println("✗ Single block failed: $e")
end

# Test 2: Two block function (simple if/else) - NO indentation
clif_two_blocks = """
function %test_if(i64) -> i64 {
block0(v0: i64):
    v1 = iconst.i64 0
    v2 = icmp slt v1, v0
    brif v2, block1, block2
block1:
    return 1
block2:
    return 0
}
"""

println("\nTest 2: Compiling two block CLIF (no indentation)")
try
    comp = NativeCodegen.compile_clif_from_string(clif_two_blocks)
    println("✓ Two block (no indentation) compiled successfully!")
catch e
    println("✗ Two block (no indentation) failed: $e")
end

# Test 3: Two block function (WITH indentation)
clif_two_blocks_indented = """
function %test_if(i64) -> i64 {
    block0(v0: i64):
        v1 = iconst.i64 0
        v2 = icmp slt v1, v0
        brif v2, block1, block2
    block1:
        return 1
    block2:
        return 0
}
"""

println("\nTest 3: Compiling two block CLIF (with indentation)")
try
    comp = NativeCodegen.compile_clif_from_string(clif_two_blocks_indented)
    println("✓ Two block (with indentation) compiled successfully!")
catch e
    println("✗ Two block (with indentation) failed: $e")
end

println("\n=== Compilation Tests Complete ===")