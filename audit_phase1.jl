# Phase 1: per-opcode behavioral audit against wasm-tools.
# For every op in OPSPECS:
#   1. build a one-instruction body with dummy immediates, encode a module
#   2. wasm-tools print -> check mnemonic matches spec.wat
#   3. wasm-tools parse the printed wat -> compare code-section bytes with ours
#   4. WasmTools.decode the wasm-tools binary -> compare Inst immediates exactly
# Two immediate sets per op: zeros and distinctive values.

using WasmTools
using WasmTools: WasmModule, Inst, MemArg, Catch, HeapType, FuncType, I32, I64, F64,
                 FuncRefT, ExternRefT, addtype!, Func, Table, TableType, Limits,
                 MemoryType, TagType, Global, GlobalType, Elem, Data, encode, decode,
                 OPSPECS

const WT = "/workspace/tools/wasm-tools-dist/wasm-tools"

function run_wt(args::Vector{String}, input::Vector{UInt8})
    inbuf = IOBuffer(input)
    out = IOBuffer(); err = IOBuffer()
    p = run(pipeline(ignorestatus(`$WT $args -`), stdin=inbuf, stdout=out, stderr=err); wait=true)
    return p.exitcode, take!(out), String(take!(err))
end

wt_print(bytes) = run_wt(["print"], bytes)
wt_parse(wat::String) = run_wt(["parse"], Vector{UInt8}(wat))

"Extract payload of first section with given id (skipping custom name matching)."
function section_payload(bytes::Vector{UInt8}, id::UInt8)
    io = IOBuffer(bytes)
    read(io, 8) # magic+version
    while !eof(io)
        sid = read(io, UInt8)
        size = WasmTools.read_uleb(io, 32)
        payload = read(io, size)
        sid == id && return payload
    end
    return nothing
end

"All non-paren lines (instruction lines) of printed wat."
function inst_lines(wat::String)
    out = String[]
    for line in split(wat, '\n')
        s = strip(line)
        isempty(s) && continue
        startswith(s, "(") && continue
        s == ")" && continue
        push!(out, String(s))
    end
    return out
end

function dummy_imm(kind::Symbol, distinctive::Bool)
    if !distinctive
        kind === :u32 && return 0
        kind === :u32vec && return [0]
        kind === :i32 && return 0
        kind === :i64 && return 0
        kind === :f32 && return 0f0
        kind === :f64 && return 0.0
        kind === :memarg && return MemArg()
        kind === :blocktype && return nothing
        kind === :heaptype && return HeapType(-16)
        kind === :reftype && return FuncRefT
        kind === :valtypevec && return [I32]
        kind === :u8 && return 0
        kind === :catchvec && return Catch[]
    else
        kind === :u32 && return 1
        kind === :u32vec && return [1, 2, 3]
        kind === :i32 && return -123456
        kind === :i64 && return -1234567890123
        kind === :f32 && return 1.5f0
        kind === :f64 && return -2.75
        kind === :memarg && return MemArg(align=2, offset=8, memidx=1)
        kind === :blocktype && return Int64(0)   # type index 0
        kind === :heaptype && return HeapType(0) # concrete index
        kind === :reftype && return ExternRefT
        kind === :valtypevec && return [F64]
        kind === :u8 && return 3                 # both null flags for br_on_cast
        kind === :catchvec && return [Catch(0,0,0), Catch(1,0,1), Catch(2,0,0), Catch(3,0,2)]
    end
    error("no dummy for $kind")
end

function build_module(body::Vector{Inst})
    m = WasmModule()
    addtype!(m, FuncType([], []))
    push!(m.funcs, Func(0, WasmTools.ValType[], body, nothing))
    push!(m.tables, Table(TableType(FuncRefT, Limits(1)), nothing))
    push!(m.tables, Table(TableType(FuncRefT, Limits(1)), nothing))
    push!(m.mems, MemoryType(1))
    push!(m.mems, MemoryType(1))
    push!(m.tags, TagType(0))
    push!(m.tags, TagType(0))
    push!(m.globals, Global(GlobalType(I32, true), [Inst(:i32_const, Int32(0))]))
    push!(m.globals, Global(GlobalType(I32, true), [Inst(:i32_const, Int32(0))]))
    push!(m.elems, Elem(:passive, FuncRefT, [[Inst(:ref_func, 0)]]))
    push!(m.elems, Elem(:passive, FuncRefT, [[Inst(:ref_func, 0)]]))
    push!(m.datas, Data(UInt8[0x01]))
    push!(m.datas, Data(UInt8[0x02]))
    return m
end

issues = String[]
ok = 0

specs = sort!(collect(values(OPSPECS)), by=s -> (s.prefix, s.sub, s.wat))

for spec in specs, distinctive in (false, true)
    distinctive && isempty(spec.imm) && continue
    imms = Tuple(dummy_imm(k, distinctive) for k in spec.imm)
    inst = Inst(spec.op, imms)
    label = "$(spec.op)$(distinctive ? " [distinctive]" : "")"
    # structural fixes so the body is parseable (print doesn't validate but
    # the binary reader needs balanced blocks)
    body = if spec.op in (:block, :loop, Symbol("if"), :try_table)
        [inst, Inst(:end)]
    elseif spec.op === Symbol("else")
        [Inst(Symbol("if"), (nothing,)), inst, Inst(:end)]
    elseif spec.op === Symbol("end")
        [Inst(:block, (nothing,)), inst]
    else
        [inst]
    end
    m = build_module(body)
    bytes = try
        encode(m)
    catch e
        push!(issues, "$label: encode threw $(sprint(showerror, e))")
        continue
    end
    code, watout, errstr = wt_print(bytes)
    if code != 0
        push!(issues, "$label: wasm-tools print FAILED: $(first(split(errstr, '\n')))")
        continue
    end
    wat = String(watout)
    lines = inst_lines(wat)
    mnems = [first(split(l)) for l in lines]
    if !(spec.wat in mnems)
        push!(issues, "$label: expected mnemonic '$(spec.wat)' not printed; got body: $(join(lines, " | "))")
        continue
    end
    # round-trip through wasm-tools parse, compare code sections byte-for-byte
    pcode, pbytes, perr = wt_parse(wat)
    if pcode != 0
        push!(issues, "$label: wasm-tools parse of printed wat FAILED: $(first(split(perr, '\n')))")
        continue
    end
    ours = section_payload(bytes, UInt8(10))
    theirs = section_payload(Vector{UInt8}(pbytes), UInt8(10))
    if ours != theirs
        push!(issues, "$label: code section bytes differ. ours=$(bytes2hex(ours)) wasm-tools=$(bytes2hex(theirs)) | printed: $(join(lines, " | "))")
        continue
    end
    # decode wasm-tools' binary, compare instructions exactly
    m2 = try
        decode(Vector{UInt8}(pbytes))
    catch e
        push!(issues, "$label: decode of wasm-tools binary threw $(sprint(showerror, e))")
        continue
    end
    if m2.funcs[1].body != body
        push!(issues, "$label: decoded body mismatch: expected $body got $(m2.funcs[1].body)")
        continue
    end
    # re-encode our decode of their bytes; byte-stable?
    re = encode(decode(Vector{UInt8}(pbytes)))
    rsec = section_payload(re, UInt8(10))
    if rsec != theirs
        push!(issues, "$label: re-encode of wasm-tools binary not byte-stable in code section: $(bytes2hex(rsec)) vs $(bytes2hex(theirs))")
        continue
    end
    global ok += 1
end

println("=== PHASE 1 RESULTS ===")
println("passed: $ok checks")
println("issues: $(length(issues))")
for i in issues
    println("ISSUE: ", i)
end
