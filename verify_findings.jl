# Verify each audit finding against current WasmTools.
using WasmTools
const WT = WasmTools
const WASM_TOOLS = "/workspace/tools/wasm-tools-dist/wasm-tools"

function wt_validate(bytes)
    mktemp() do p, io
        write(io, bytes); close(io)
        success(pipeline(`$WASM_TOOLS validate --features all $p`, stderr=devnull))
    end
end
wt_parse(wat) = mktemp() do p, io
    write(io, wat); close(io)
    read(`$WASM_TOOLS parse $p`)
end

println("=== F1/F5/F8: blocktype concrete ref ===")
b = hex2bytes("0061736d01000000010401600000030201000a0a010800026300000b1a0b")
println("valid per wasm-tools: ", wt_validate(b))
m = WT.decode(b)
try
    WT.encode(m); println("encode OK (already fixed?)")
catch e
    println("encode threw: ", sprint(showerror, e))
end

println("\n=== F2/F9: sleb maxbits ===")
# i64.const with 10-byte payload final byte 0x01
body = UInt8[0x42, 0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x01, 0x0b]
mod1 = vcat(hex2bytes("0061736d01000000010401600000030201000a"),
            UInt8[length(body)+4], UInt8[0x01, length(body)+2, 0x00], body)
try
    m1 = WT.decode(mod1); println("i64.const overlong: decoded as ", m1.funcs[1].body[1])
catch e
    println("i64.const overlong threw: ", sprint(showerror, e))
end
println("wasm-tools accepts: ", wt_validate(mod1))
# i32.const FF FF FF FF 0F
body2 = UInt8[0x41, 0xFF,0xFF,0xFF,0xFF,0x0F, 0x1a, 0x0b]
mod2 = vcat(hex2bytes("0061736d01000000010401600000030201000a"),
            UInt8[length(body2)+4], UInt8[0x01, length(body2)+2, 0x00], body2)
try
    m2 = WT.decode(mod2); println("i32.const dirty: decoded as ", m2.funcs[1].body[1])
catch e
    println("i32.const dirty threw: ", typeof(e), " ", sprint(showerror, e))
end
println("wasm-tools accepts: ", wt_validate(mod2))

println("\n=== F9b: uleb 64 10th byte ===")
io = IOBuffer(UInt8[0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x7E])
try
    println("read_uleb -> ", WT.read_uleb(io, 64))
catch e
    println("read_uleb threw: ", sprint(showerror, e))
end

println("\n=== F3: dead :reftype kind ===")
kinds = sort(unique(reduce(vcat, [s.imm for s in values(WT.OPSPECS)]; init=Symbol[])))
println("used kinds: ", kinds)

println("\n=== F6: elem flavor ===")
e7 = hex2bytes("0061736d01000000090401077000")
println("flag7 valid: ", wt_validate(e7))
re = WT.encode(WT.decode(e7))
println("re-encoded == orig: ", re == e7, "  re: ", bytes2hex(re))

println("\n=== F7: import func names ===")
nb = hex2bytes("0061736d01000000010401600000020701016501660000030201000a0601040010000b001b046e616d650114020008696d706f727465640107646566696e6564")
println("valid: ", wt_validate(nb))
mn = WT.decode(nb)
rb = WT.encode(mn)
println("roundtrip == orig: ", rb == nb)
println("contains 'imported': ", occursin("imported", String(copy(rb))))

println("\n=== F10: func section without code section ===")
fb = vcat(hex2bytes("0061736d01000000"), hex2bytes("010401600000"), hex2bytes("03020100"))
println("wasm-tools accepts: ", wt_validate(fb))
try
    mf = WT.decode(fb); println("decoded, nfuncs=", length(mf.funcs), " body=", mf.funcs[1].body)
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F11: datacount mismatch ===")
db = vcat(hex2bytes("0061736d01000000"),
          UInt8[0x05, 0x03, 0x01, 0x00, 0x01],     # memory section
          UInt8[0x0c, 0x01, 0x02],                  # datacount = 2
          UInt8[0x0b, 0x03, 0x01, 0x01, 0x00])      # data section: 1 passive empty
println("wasm-tools accepts: ", wt_validate(db))
try
    md = WT.decode(db); println("decoded, ndatas=", length(md.datas))
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F12: heaptype -1 ===")
hb = vcat(hex2bytes("0061736d01000000"),
          hex2bytes("0105016000017000"),  # hmm, just build via parse instead
          )
body3 = UInt8[0xD0, 0x7F, 0x1a, 0x0b]
mod3 = vcat(hex2bytes("0061736d01000000010401600000030201000a"),
            UInt8[length(body3)+4], UInt8[0x01, length(body3)+2, 0x00], body3)
println("wasm-tools accepts: ", wt_validate(mod3))
try
    m3 = WT.decode(mod3); println("decoded: ", m3.funcs[1].body[1])
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F13: UTF-8 ===")
# import with module name byte 0xFF
ub = vcat(hex2bytes("0061736d01000000"), hex2bytes("010401600000"),
          UInt8[0x02, 0x08, 0x01, 0x01, 0xFF, 0x01, 0x66, 0x00, 0x00])
println("wasm-tools accepts: ", wt_validate(ub))
try
    mu = WT.decode(ub); println("decoded, import mod bytes: ", codeunits(mu.imports[1].mod))
catch e
    println("threw: ", sprint(showerror, e))
end
mB = WasmModule()
push!(mB.exports, Export(String(UInt8[0xff,0xfe]), :func, 0))
try
    eb = WT.encode(mB); println("encoded bad-utf8 export OK; wasm-tools accepts: ", wt_validate(eb))
catch e
    println("encode threw: ", sprint(showerror, e))
end

println("\n=== F14: name section errors ===")
# custom section name="name", subsection id 1 claiming length 5 with 1 byte payload
ns = vcat(UInt8[0x04], codeunits("name"), UInt8[0x01, 0x05, 0x00])
cb = vcat(hex2bytes("0061736d01000000"), UInt8[0x00, UInt8(length(ns))], ns)
println("wasm-tools accepts: ", wt_validate(cb))
try
    mc = WT.decode(cb); println("decoded OK, customs=", length(mc.customs))
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F15: memarg ===")
mm = WasmModule()
push!(mm.mems, MemoryType(Limits(1, nothing)))
addfunc!(mm, nothing, FuncType(ValType[], ValType[]), ValType[],
         [WT.Instructions.i32_const(0), WT.Instructions.i64_load(MemArg(align=64, offset=4)), WT.Instructions.drop()])
try
    be = WT.encode(mm)
    println("encoded align=64 OK; wasm-tools validate: ", wt_validate(be))
    try
        WT.decode(be); println("self-decode OK")
    catch e
        println("self-decode threw: ", sprint(showerror, e))
    end
catch e
    println("encode threw: ", sprint(showerror, e))
end
# decoder accepts flags >= 0x80
body4 = UInt8[0x41, 0x00, 0x29, 0x80, 0x01, 0x00, 0x1a, 0x0b]  # i64.load align=128(flags) offset=0
mod4 = vcat(hex2bytes("0061736d01000000010401600000030201000505010001"),
            UInt8[0x0a], UInt8[length(body4)+4], UInt8[0x01, length(body4)+2, 0x00], body4)
println("wasm-tools accepts flags=0x80: ", wt_validate(mod4))
try
    m4 = WT.decode(mod4); println("decoded: ", m4.funcs[1].body[2])
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F16: limits shared bit ===")
tb = vcat(hex2bytes("0061736d01000000"), UInt8[0x04, 0x05, 0x01, 0x70, 0x03, 0x00, 0x01])
println("wasm-tools accepts shared table: ", wt_validate(tb))
try
    mt = WT.decode(tb); println("decoded, shared=", mt.tables[1].type.limits.shared)
catch e
    println("threw: ", sprint(showerror, e))
end

println("\n=== F18: truncated -> EOFError ===")
tr = vcat(hex2bytes("0061736d01000000"), UInt8[0x01])
try
    WT.decode(tr); println("decoded?!")
catch e
    println("threw: ", typeof(e))
end
