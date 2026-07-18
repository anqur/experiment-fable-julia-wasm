# Test the call mechanism by calling __jl_string_len
# This avoids the complex %new/store path
# Usage: julia +nightly --project=. NativeCodegen/test/debug_call_raw.jl

using NativeCodegen: NCGInterp
using NativeCodegen

# Function that calls ncodeunits (which invokes string length load)
# We already know this works. Now test if call-based version also works.
#
# Instead of modifying the codegen, let's trace what happens with
# the full allocation path by disassembling the generated code.

function alloc_vec(n::Int64)
    return Vector{Int64}(undef, n)
end

# Get the IR
interp = NCGInterp()
tt = Base.signature_type(alloc_vec, Tuple{Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rettype = result[1]

println("Return type: $rettype")
println()
for (i, stmt) in enumerate(ir.stmts)
    println("  [$i] $(stmt[:stmt]) :: $(stmt[:type])")
end
