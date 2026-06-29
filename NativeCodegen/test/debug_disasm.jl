# Check the generated code for allocation function
# Usage: julia +nightly --project=. NativeCodegen/test/debug_disasm.jl

using NativeCodegen

function alloc_vec(n::Int64)
    return Vector{Int64}(undef, n)
end

comp = compile_native(alloc_vec, Tuple{Int64}; name="alloc_vec")

# Disassemble the full .so text section
so = comp.so_path
# Find all function symbols and their ranges using nm
sym_addrs = Dict{String,Int}()
for line in eachline(`nm $so`)
    parts = split(line)
    if length(parts) >= 3 && parts[3][1] == '_'
        addr = parse(Int, "0x" * parts[1])
        sym_addrs[parts[3]] = addr
    end
end

println("Functions found:")
for (name, addr) in sort(collect(sym_addrs), by=x->x[2])
    println("  0x$(string(addr, base=16)) $name")
end

# Disassemble from the start of alloc_vec (it's small, ~100 bytes)
alloc_addr = get(sym_addrs, "_alloc_vec", nothing)
if alloc_addr !== nothing
    # Find next function to get the size
    addrs = sort(collect(values(sym_addrs)))
    nxt = nothing
    for a in addrs
        if a > alloc_addr
            nxt = a
            break
        end
    end
    size_hint = nxt !== nothing ? nxt - alloc_addr : 200
    println("\nDisassembly of alloc_vec (0x$(string(alloc_addr, base=16)), ~$size_hint bytes):")

    # Use otool to disassemble just this function
    for line in eachline(`otool -tV $so`)
        if startswith(strip(line), "_alloc_vec") ||
           (startswith(strip(line), "0000") && occursin(r"^\s+[0-9a-f]+:", line))
            println(line)
        end
    end
end
