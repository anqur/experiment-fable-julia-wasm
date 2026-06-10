# Independent verification: does Base.read(WasmMemory) return an unrooted view
# into wasmtime store memory that becomes dangling after the Store is GC'd?
using WasmtimeRunner

wasm = read(joinpath(@__DIR__, "mem.wasm"))

buf = let
    eng = Engine()
    store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, wasm))
    read(inst["mem"])           # Vector{UInt8} from unsafe_wrap
end
println("buf length = ", length(buf), ", buf[1] = ", repr(buf[1]), " buf[2] = ", repr(buf[2]))
@assert buf[1] == 0xaa && buf[2] == 0xbb

# Store is now unreachable; force its finalizer (wasmtime_store_delete).
GC.gc(); GC.gc(); GC.gc()

println("touching dangling buffer...")
s = UInt64(0)
for i in 1:length(buf)
    global s += buf[i]
end
println("SURVIVED: sum = ", s, ", buf[1] = ", repr(buf[1]),
        buf[1] == 0xaa ? " (value preserved?!)" : " (SILENT GARBAGE — was 0xaa)")
