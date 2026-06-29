# Dump alloc_vec disassembly
# Usage: julia +nightly --project=. NativeCodegen/test/debug_disasm2.jl

using NativeCodegen

function alloc_vec(n::Int64)
    return Vector{Int64}(undef, n)
end

comp = compile_native(alloc_vec, Tuple{Int64}; name="alloc_vec")
so = comp.so_path

# Use otool to get the complete text section
println("Complete text disassembly:")
for line in eachline(`otool -tV $so`)
    println(line)
end
