using WasmTools
const WT = WasmTools
const WASM_TOOLS = "/workspace/tools/wasm-tools-dist/wasm-tools"
wt_validate(bytes) = mktemp() do p, io
    write(io, bytes); close(io)
    success(pipeline(`$WASM_TOOLS validate --features all $p`, stderr=devnull))
end

sec(id, payload) = vcat(UInt8[id, UInt8(length(payload))], Vector{UInt8}(payload))
function codesec(bodybytes)
    entry = vcat(UInt8[0x00], Vector{UInt8}(bodybytes))   # 0 local decls
    payload = vcat(UInt8[0x01, UInt8(length(entry))], entry)
    return sec(0x0a, payload)
end
header = hex2bytes("0061736d01000000")
typesec = sec(0x01, UInt8[0x01, 0x60, 0x00, 0x00])
funcsec = sec(0x03, UInt8[0x01, 0x00])
memsec  = sec(0x05, UInt8[0x01, 0x00, 0x01])

function tryd(label, bytes)
    println(label, " wasm-tools accepts: ", wt_validate(bytes))
    try
        m = WT.decode(bytes)
        println(label, " WT decoded: ", isempty(m.funcs) ? "ok" : m.funcs[1].body)
    catch e
        println(label, " WT threw: ", typeof(e), ": ", sprint(showerror, e))
    end
end

# F2: i64.const 10-byte, final byte 0x01 (bad sign ext)
tryd("i64 overlong", vcat(header, typesec, funcsec,
    codesec(UInt8[0x42, 0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x01, 0x1a, 0x0b])))
# F2: i32.const FF FF FF FF 0F
tryd("i32 dirty", vcat(header, typesec, funcsec,
    codesec(UInt8[0x41, 0xFF,0xFF,0xFF,0xFF,0x0F, 0x1a, 0x0b])))
# i32.const 6-byte of 0
tryd("i32 6-byte", vcat(header, typesec, funcsec,
    codesec(UInt8[0x41, 0x80,0x80,0x80,0x80,0x80,0x00, 0x1a, 0x0b])))
# blocktype s33 of 0 in 6 bytes
tryd("s33 6-byte blocktype", vcat(header, typesec, funcsec,
    codesec(UInt8[0x02, 0x80,0x80,0x80,0x80,0x80,0x00, 0x0b, 0x0b])))
# F12: ref.null 0x7F (heaptype -1)
tryd("heaptype -1", vcat(header, typesec, funcsec,
    codesec(UInt8[0xD0, 0x7F, 0x1a, 0x0b])))
# F15 decode: memarg flags >= 0x80
tryd("memarg flags 0x80", vcat(header, typesec, funcsec, memsec,
    codesec(UInt8[0x41, 0x00, 0x29, 0x80, 0x01, 0x00, 0x1a, 0x0b])))
# F13 decode: import module name 0xFF
tryd("bad utf8 import", vcat(header, typesec,
    sec(0x02, UInt8[0x01, 0x01, 0xFF, 0x01, 0x66, 0x00, 0x00]), funcsec,
    codesec(UInt8[0x0b])))
# F9b: limits min as overlong u64
tryd("uleb64 dirty 10th byte", vcat(header,
    sec(0x05, UInt8[0x01, 0x00, 0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x7E])))
