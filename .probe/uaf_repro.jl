# Repro: Base.read(WasmMemory) returns an unsafe_wrap'd Array that does not
# root the Store. If the Store is collected, the Array points to unmapped memory.
using WasmtimeRunner
using WasmTools, WasmTools.Instructions

function memmod()
    m = WasmModule()
    push!(m.mems, MemoryType(Limits(8, 8)))   # 512 KiB so unmap is observable
    push!(m.exports, Export("mem", :memory, 0))
    push!(m.datas, Data(:active, 0, [i32_const(0)], UInt8[0xAA, 0xBB]))
    return encode(m)
end

buf = let
    eng = Engine(); store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, memmod()))
    read(inst["mem"])    # Vector{UInt8} view into store-owned linear memory
end
@assert buf[1] == 0xAA
GC.gc(); GC.gc(); GC.gc()   # store unreachable -> finalizer -> wasmtime_store_delete
sleep(0.1)
println("reading dangling buffer of length ", length(buf))
function touch(buf)
    s = UInt64(0)
    for i in 1:length(buf)      # touch every page
        s += buf[i]
    end
    return s
end
s = touch(buf)
println("survived read, sum=", s, " buf[1]=", buf[1], " (silent UAF: value may be garbage)")
