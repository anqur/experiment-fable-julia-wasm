using NativeCodegen
using NativeCodegen: NCGInterp

# Minimal pop! to debug
popone(a::Vector{Int64}) = pop!(a)

interp = NCGInterp()
tt = Base.signature_type(popone, Tuple{Vector{Int64}})
m = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(m[1].method, tt, Core.svec())
r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, rt = r[1]

println("IR for pop!(a::Vector{Int64}):")
for (i, s) in enumerate(ir.stmts)
    println("%", i, " :: ", s[:type], "  ", s[:stmt])
end

println("\n\nNow compiling and printing Cranelift output...")

# Patch compile_native to dump CLIF
# We need to call the Rust builder directly with debug flag

# Let's just compile and see if we can get CLIF dump
comp = NativeCodegen.compile_native(popone, Tuple{Vector{Int64}}; name="popone")
println("\nGenerated .o at: ", comp.so_path)

# Try to disassemble
run(`objdump -d $(comp.so_path)`)
