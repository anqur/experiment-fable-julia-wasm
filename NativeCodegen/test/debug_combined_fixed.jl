# Debug the fixed combined function

using NativeCodegen

function test_combined(s::String)
    if isempty(s)
        result = 0
        return result
    else
        len1 = ncodeunits(s)
        len2 = lastindex(s)
        return len1 + len2
    end
end

println("=== Testing Fixed Combined Function ===")

interp = NativeCodegen.NCGInterp()
clif = NativeCodegen.compile_to_clif(interp, test_combined, Tuple{String})
println("Generated CLIF:")
println(clif)

println("\n=== Debug Complete ===")