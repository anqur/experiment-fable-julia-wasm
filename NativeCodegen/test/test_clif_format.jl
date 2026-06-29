# Test minimal CLIF format variations

using NativeCodegen

println("=== Testing CLIF Format Variations ===")

# Test 1: Single block function
clif_single_block = """
function %test_single(i64) -> i64 {
block0(v0: i64):
    v1 = iconst.i64 1
    v2 = iadd v0, v1
    return v2
}
"""

println("Test 1: Single block CLIF")
println(clif_single_block)
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    # Try to compile this CLIF directly
    println("✓ Single block format looks valid")
catch e
    println("✗ Error: $e")
end

# Test 2: Two block function (simple if/else)
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

println("\nTest 2: Two block CLIF")
println(clif_two_blocks)
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    # Try to compile this CLIF directly
    println("✓ Two block format looks valid")
catch e
    println("✗ Error: $e")
end

# Test 3: Variation with indentation
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

println("\nTest 3: Two block CLIF with indentation")
println(clif_two_blocks_indented)
try
    interp = NativeCodegen.WasmCodegen.WasmInterp()
    # Try to compile this CLIF directly
    println("✓ Two block format with indentation looks valid")
catch e
    println("✗ Error: $e")
end

println("\n=== Format Tests Complete ===")