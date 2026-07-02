using JuliaSyntax: JuliaSyntax
using NativeCodegen

# Add a temporary debug patch to emit_invoke
# We'll read the file, add debug output, then run

# First, let me check: for is_leaf, does isnothing reach emit_invoke or emit_globalref?
# Let me patch a print into emit_invoke at the isnothing handler

code = read("/home/anqur/workspace/experiment-fable-julia-wasm/NativeCodegen/src/builder_emit.jl", String)

# Add a debug print before the isnothing handler
debug_line = "    # DEBUG: isnothing invoke reached"
new_code = replace(code, "# isnothing(x) → null pointer check (icmp_eq val, 0)" => "# isnothing(x) → null pointer check (icmp_eq val, 0)\n    @info \"isnothing handler reached\" fn_name length(args)")

# Write the patched file
write("/home/anqur/workspace/experiment-fable-julia-wasm/NativeCodegen/src/builder_emit_patched.jl", new_code)

println("Patched file written. Testing...")

# Now directly patch and test
include_string(@__MODULE__, "using Logging")

# Let me instead just add a println in the handler temporarily
