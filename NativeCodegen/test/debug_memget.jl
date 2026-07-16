using NativeCodegen: compile_native, native_callable_from_so, WasmInterp
import Base.JuliaSyntax.Tokenize: _kw_hash

# Minimal: index a host Memory{UInt8}
f(mem::Memory{UInt8}, i::Int) = mem[i]
println("host _kw_hash.slots[1] = ", _kw_hash.slots[1])

comp = compile_native(f, Tuple{Memory{UInt8}, Int}; name="memget")
nf = native_callable_from_so(comp, UInt8, Memory{UInt8}, Int)
println("native _kw_hash.slots[1] = ", nf(_kw_hash.slots, 1), " (host ", _kw_hash.slots[1], ")")
rm(comp.so_path)
