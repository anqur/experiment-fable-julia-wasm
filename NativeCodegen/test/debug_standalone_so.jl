# Probe: is the generated .so actually standalone (independent of the Julia
# runtime that compiled it)?
#
# Hypothesis: the .so bakes Julia-process-specific heap addresses in as immediate
# constants (String/Symbol literals, DataType pointers, the nothing-tag, module
# const tables). It therefore only works when dlopen'd back into the SAME Julia
# process that compiled it. Loading it in a foreign process (pure Rust) crashes.
#
# This probe compiles two functions to fixed .so paths and prints the baked
# pointer values from the compiler's side, so we can correlate them with the
# immediates we then find in the disassembly.

using NativeCodegen
using NativeCodegen: ENTRY_SYMBOL_PREFIX

SO_LIT   = "/tmp/ncg_standalone_literal.so"   # f() = "hello"
SO_NCODE = "/tmp/ncg_standalone_ncode.so"     # g(s::String) = ncodeunits(s)

# 1) A function that returns a String literal. The literal's heap pointer is
#    baked into the entry as a TYPE_PTR immediate.
lit() = "hello"

comp1 = compile_native(lit, Tuple{}; name="lit")
cp(comp1.so_path, SO_LIT)
println("=== literal .so ===")
println("  path      = ", SO_LIT)
println("  symbol    = ", comp1.func_name)
println("  baked ptr of \"hello\" = 0x", string(reinterpret(UInt64, pointer_from_objref("hello")); base=16))
println("  baked ptr of String type = 0x", string(reinterpret(UInt64, pointer_from_objref(String)); base=16))
println("  nothing tag             = 0x", string(NativeCodegen.get_nothing_tag(); base=16))

# 2) A function taking a Julia String. Shows the entry ABI expects a Julia String
#    object (length at +0, bytes at +8), NOT raw C bytes.
ncu(s::String) = Core.sizeof(s)
comp2 = compile_native(ncu, Tuple{String}; name="ncu")
cp(comp2.so_path, SO_NCODE)
println("\n=== ncodeunits .so ===")
println("  path      = ", SO_NCODE)
println("  symbol    = ", comp2.func_name)

println("\nProbe complete. Now inspect with nm/otool from bash.")
