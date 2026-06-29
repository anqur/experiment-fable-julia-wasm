# Debug: compile allocation function and inspect disassembly
# Usage: julia +nightly --project=. NativeCodegen/test/debug_alloc_disasm.jl

using NativeCodegen

mutable struct Point
    x::Int64
    y::Int64
end

function sf_new(x::Int64, y::Int64)
    return Point(x, y)
end

comp = compile_native(sf_new, Tuple{Int64,Int64}; name="new_pt")
so = comp.so_path

# Find the new_pt function address
println("=== Symbols ===")
for line in eachline(`nm $so`)
    parts = split(line)
    if length(parts) >= 3 && occursin("new_pt", parts[3])
        println("  $line")
    end
end

# Dump raw otool output around _new_pt
println("\n=== _new_pt raw otool (all lines) ===")
function extract_func_raw(so_path, func_name)
    in_func = false
    line_count = 0
    for line in eachline(`otool -tV $so_path`)
        stripped = strip(line)
        if startswith(stripped, "_$(func_name):")
            in_func = true
            line_count = 0
        end
        if in_func
            println(line)
            line_count += 1
            if line_count > 50
                break
            end
        end
    end
end
extract_func_raw(so, "new_pt")

# Also try objdump if available
objdump_path = "/Users/anqur/.julia/juliaup/julia-nightly/Julia-1.14.app/Contents/Resources/julia/libexec/julia/lld"
println("\n=== lld (ld.lld) disassembly attempt ===")
# Use gobjdump if llvm-objdump is available
for tool in ["llvm-objdump", "gobjdump"]
    if success(`which $tool`)
        println("Found $tool")
        for line in eachline(`$tool -d --disassemble-symbols=_new_pt $so`)
            println(line)
        end
        break
    end
end
