# Debug: numeric_flags ireduce validator error
using NativeCodegen
import JuliaSyntax

println("=== Debug numeric_flags ireduce issue ===\n")

# numeric_flags(f::RawFlags) = Int((f >> 8) % UInt8)
# RawFlags = UInt16

f1(a::JuliaSyntax.RawFlags) = JuliaSyntax.numeric_flags(a)
println("Trying numeric_flags(RawFlags)...")
try
    comp = compile_native(f1, Tuple{JuliaSyntax.RawFlags}; name="debug_numflags")
    println("✅ compiled OK!")
    rm(comp.so_path)
catch e
    println("❌ ", typeof(e).name.name)
    println("   ", sprint(showerror, e)[1:500])
end

# Also try set_numeric_flags
println("\nTrying set_numeric_flags(Int64)...")
f2(n::Int64) = JuliaSyntax.set_numeric_flags(n)
try
    comp = compile_native(f2, Tuple{Int64}; name="debug_setnumflags")
    println("✅ compiled OK!")
    rm(comp.so_path)
catch e
    println("❌ ", typeof(e).name.name)
    println("   ", sprint(showerror, e)[1:500])
end

# Also try a minimal reproduction: (x >> 8) % UInt8
println("\nTrying minimal: (x::UInt16) -> Int((x >> 8) % UInt8)...")
f3(x::UInt16) = Int((x >> 8) % UInt8)
try
    comp = compile_native(f3, Tuple{UInt16}; name="debug_min_ireduce")
    println("✅ compiled OK!")
    rm(comp.so_path)
catch e
    println("❌ ", typeof(e).name.name)
    println("   ", sprint(showerror, e)[1:500])
end

println("\n=== Done ===")
