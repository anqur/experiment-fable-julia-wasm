# Phase 2: wat-authored immediate exactness + byte stability vs wasm-tools parse.
using WasmTools
using WasmTools: Inst, MemArg, Catch, HeapType, RefType, NumType, I32, I64, F32, F64, V128,
                 FuncRefT, ExternRefT, AnyRefT, encode, decode,
                 FuncHT, ExternHT, AnyHT, EqHT, I31HT, StructHT, ArrayHT, ExnHT,
                 NoneHT, NoFuncHT, NoExternHT, NoExnHT

const WT = "/workspace/tools/wasm-tools-dist/wasm-tools"

function run_wt(args::Vector{String}, input::Vector{UInt8})
    inbuf = IOBuffer(input)
    out = IOBuffer(); err = IOBuffer()
    p = run(pipeline(ignorestatus(`$WT $args -`), stdin=inbuf, stdout=out, stderr=err); wait=true)
    return p.exitcode, take!(out), String(take!(err))
end

issues = String[]
ok = 0

"Remove the datacount section (id 12) so unconditional emission doesn't add noise."
function strip_datacount(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    out = IOBuffer()
    write(out, read(io, 8))
    while !eof(io)
        sid = read(io, UInt8)
        size = WasmTools.read_uleb(io, 32)
        payload = read(io, size)
        sid == 12 && continue
        write(out, sid); WasmTools.write_uleb(out, length(payload)); write(out, payload)
    end
    return take!(out)
end

# Standard preamble: type 0 = ()->(), type 1 = (i32)->(i32); func 0 of type 0.
# `body` goes inside func 0. Each case: (name, wat, expected_insts_or_nothing, check_fn_or_nothing)
PRE = """
(module
  (type (func))
  (type (func (param i32) (result i32)))
  (type (struct (field (mut i8)) (field i16) (field (mut i32))))
  (type (array (mut i64)))
  (tag (type 0))
  (tag (type 0))
  (memory 1)
  (memory 1)
  (table 2 funcref)
  (table 2 externref)
  (global (mut i32) (i32.const 7))
  (global (mut i64) (i64.const 9))
  (elem func 0)
  (elem func 0)
  (data "ab")
  (data "cd")
  (func (type 0)
"""
POST = """
  )
)
"""

E(op, args...) = Inst(op, args)

cases = Vector{Tuple{String,String,Union{Nothing,Vector{Inst}}}}()

push!(cases, ("memarg offset/align i32.load",
    "i32.load offset=8 align=4", [E(:i32_load, MemArg(align=2, offset=8))]))
push!(cases, ("memarg align=1 i64.store8",
    "i64.store8 offset=3 align=1", [E(:i64_store8, MemArg(align=0, offset=3))]))
push!(cases, ("memarg memidx f64.load",
    "f64.load 1 offset=16 align=8", [E(:f64_load, MemArg(align=3, offset=16, memidx=1))]))
push!(cases, ("memarg large offset i32.load16_u",
    "i32.load16_u offset=4294967295", [E(:i32_load16_u, MemArg(align=1, offset=0xFFFFFFFF))]))
push!(cases, ("br_table 1 2 3 default 0",
    "br_table 1 2 3 0", [E(:br_table, UInt32[1,2,3], UInt32(0))]))
push!(cases, ("i32.const -123456", "i32.const -123456", [E(:i32_const, Int32(-123456))]))
push!(cases, ("i32.const INT32_MIN", "i32.const -2147483648", [E(:i32_const, typemin(Int32))]))
push!(cases, ("i32.const 4294967295 (=-1)", "i32.const 4294967295", [E(:i32_const, Int32(-1))]))
push!(cases, ("i64.const -123456", "i64.const -123456", [E(:i64_const, Int64(-123456))]))
push!(cases, ("i64.const INT64_MIN", "i64.const -9223372036854775808", [E(:i64_const, typemin(Int64))]))
push!(cases, ("i64.const UINT64_MAX (=-1)", "i64.const 18446744073709551615", [E(:i64_const, Int64(-1))]))
push!(cases, ("f32.const 1.5", "f32.const 1.5", [E(:f32_const, 1.5f0)]))
push!(cases, ("f32.const -inf", "f32.const -inf", [E(:f32_const, -Inf32)]))
push!(cases, ("f64.const pi-ish", "f64.const 3.14159265358979", [E(:f64_const, 3.14159265358979)]))
push!(cases, ("f32.const nan payload", "f32.const nan:0x200001", nothing))
push!(cases, ("f64.const -nan", "f64.const -nan", nothing))
push!(cases, ("call_indirect type+table",
    "call_indirect 1 (type 1)", [E(:call_indirect, UInt32(1), UInt32(1))]))
push!(cases, ("return_call_indirect type+table",
    "return_call_indirect 1 (type 1)", [E(:return_call_indirect, UInt32(1), UInt32(1))]))
push!(cases, ("typed select", "select (result externref)", [E(:select_t, [ExternRefT])]))
push!(cases, ("memory.size 1", "memory.size 1", [E(:memory_size, UInt32(1))]))
push!(cases, ("memory.grow 1", "memory.grow 1", [E(:memory_grow, UInt32(1))]))
push!(cases, ("memory.init data1 mem1", "memory.init 1 1", [E(:memory_init, UInt32(1), UInt32(1))]))
push!(cases, ("memory.copy 1 0 (dst src)", "memory.copy 1 0", [E(:memory_copy, UInt32(1), UInt32(0))]))
push!(cases, ("memory.fill 1", "memory.fill 1", [E(:memory_fill, UInt32(1))]))
push!(cases, ("data.drop 1", "data.drop 1", [E(:data_drop, UInt32(1))]))
push!(cases, ("table.init table1 elem0", "table.init 1 0", [E(:table_init, UInt32(0), UInt32(1))]))
push!(cases, ("table.copy 1 0 (dst src)", "table.copy 1 0", [E(:table_copy, UInt32(1), UInt32(0))]))
push!(cases, ("elem.drop 1", "elem.drop 1", [E(:elem_drop, UInt32(1))]))
push!(cases, ("table.grow/size/fill 1", "table.grow 1 table.size 1 table.fill 1",
    [E(:table_grow, UInt32(1)), E(:table_size, UInt32(1)), E(:table_fill, UInt32(1))]))

# ref.null with every abstract heap type
for (watname, ht) in [("func", FuncHT), ("extern", ExternHT), ("any", AnyHT), ("eq", EqHT),
                      ("i31", I31HT), ("struct", StructHT), ("array", ArrayHT), ("exn", ExnHT),
                      ("none", NoneHT), ("nofunc", NoFuncHT), ("noextern", NoExternHT),
                      ("noexn", NoExnHT)]
    push!(cases, ("ref.null $watname", "ref.null $watname", [E(:ref_null, ht)]))
end
push!(cases, ("ref.null concrete 3", "ref.null 3", [E(:ref_null, HeapType(3))]))

# ref.test / ref.cast null and non-null, abstract and concrete
push!(cases, ("ref.test (ref any)", "ref.test (ref any)", [E(:ref_test, AnyHT)]))
push!(cases, ("ref.test (ref null any)", "ref.test (ref null any)", [E(:ref_test_null, AnyHT)]))
push!(cases, ("ref.cast (ref 2)", "ref.cast (ref 2)", [E(:ref_cast, HeapType(2))]))
push!(cases, ("ref.cast (ref null 2)", "ref.cast (ref null 2)", [E(:ref_cast_null, HeapType(2))]))

# br_on_cast: all four flag combos (flags bit0 = from nullable, bit1 = to nullable)
push!(cases, ("br_on_cast nn", "br_on_cast 0 (ref any) (ref 2)",
    [E(:br_on_cast, 0x00, UInt32(0), AnyHT, HeapType(2))]))
push!(cases, ("br_on_cast null->nonnull", "br_on_cast 0 (ref null any) (ref 2)",
    [E(:br_on_cast, 0x01, UInt32(0), AnyHT, HeapType(2))]))
push!(cases, ("br_on_cast nonnull->null", "br_on_cast 0 (ref any) (ref null 2)",
    [E(:br_on_cast, 0x02, UInt32(0), AnyHT, HeapType(2))]))
push!(cases, ("br_on_cast_fail null->null", "br_on_cast_fail 0 (ref null any) (ref null 2)",
    [E(:br_on_cast_fail, 0x03, UInt32(0), AnyHT, HeapType(2))]))

# GC two-index ops
push!(cases, ("struct.get 2 1", "struct.get 2 1", [E(:struct_get, UInt32(2), UInt32(1))]))
push!(cases, ("struct.get_s 2 0", "struct.get_s 2 0", [E(:struct_get_s, UInt32(2), UInt32(0))]))
push!(cases, ("struct.get_u 2 1", "struct.get_u 2 1", [E(:struct_get_u, UInt32(2), UInt32(1))]))
push!(cases, ("struct.set 2 2", "struct.set 2 2", [E(:struct_set, UInt32(2), UInt32(2))]))
push!(cases, ("array.new_fixed 3 5", "array.new_fixed 3 5", [E(:array_new_fixed, UInt32(3), UInt32(5))]))
push!(cases, ("array.new_data 3 1", "array.new_data 3 1", [E(:array_new_data, UInt32(3), UInt32(1))]))
push!(cases, ("array.new_elem 3 1", "array.new_elem 3 1", [E(:array_new_elem, UInt32(3), UInt32(1))]))
push!(cases, ("array.copy 3 3", "array.copy 3 3", [E(:array_copy, UInt32(3), UInt32(3))]))
push!(cases, ("array.init_data 3 1", "array.init_data 3 1", [E(:array_init_data, UInt32(3), UInt32(1))]))
push!(cases, ("array.init_elem 3 1", "array.init_elem 3 1", [E(:array_init_elem, UInt32(3), UInt32(1))]))

# blocktype forms
for (t, vt) in [("i32", I32), ("i64", I64), ("f32", F32), ("f64", F64), ("v128", V128)]
    push!(cases, ("block (result $t)", "block (result $t) unreachable end",
        [E(:block, vt), E(:unreachable), E(Symbol("end"))]))
end
for (t, vt) in [("funcref", RefType(true, FuncHT)), ("externref", RefType(true, ExternHT)),
                ("anyref", RefType(true, AnyHT)), ("eqref", RefType(true, EqHT)),
                ("i31ref", RefType(true, I31HT)), ("structref", RefType(true, StructHT)),
                ("arrayref", RefType(true, ArrayHT)), ("exnref", RefType(true, ExnHT)),
                ("nullref", RefType(true, NoneHT)), ("nullfuncref", RefType(true, NoFuncHT)),
                ("nullexternref", RefType(true, NoExternHT)), ("nullexnref", RefType(true, NoExnHT)),
                ("(ref 2)", RefType(false, HeapType(2))), ("(ref null 3)", RefType(true, HeapType(3)))]
    push!(cases, ("loop (result $t)", "loop (result $t) unreachable end",
        [E(:loop, vt), E(:unreachable), E(Symbol("end"))]))
end
push!(cases, ("if with functype index", "i32.const 1 if (type 1) (param i32) (result i32) end",
    [E(:i32_const, Int32(1)), E(Symbol("if"), Int64(1)), E(Symbol("end"))]))

# try_table catch clause kinds with distinctive tags/labels
push!(cases, ("try_table all catch kinds",
    "block block try_table (catch 1 0) (catch_ref 0 1) (catch_all 2) (catch_all_ref 1) end end end",
    [E(:block, nothing), E(:block, nothing),
     E(:try_table, nothing, [Catch(0,1,0), Catch(1,0,1), Catch(2,0,2), Catch(3,0,1)]),
     E(Symbol("end")), E(Symbol("end")), E(Symbol("end"))]))
push!(cases, ("throw tag 1", "throw 1", [E(Symbol("throw"), UInt32(1))]))

# locals/globals/tables distinctive indices
push!(cases, ("variable ops", "local.get 0 local.set 0 local.tee 0 global.get 1 global.set 1 drop",
    [E(:local_get, UInt32(0)), E(:local_set, UInt32(0)), E(:local_tee, UInt32(0)),
     E(:global_get, UInt32(1)), E(:global_set, UInt32(1)), E(:drop)]))
push!(cases, ("table.get/set 1", "table.get 1 table.set 1",
    [E(:table_get, UInt32(1)), E(:table_set, UInt32(1))]))
push!(cases, ("branches", "br 0 br_if 0 br_on_null 0 br_on_non_null 0",
    [E(:br, UInt32(0)), E(:br_if, UInt32(0)), E(:br_on_null, UInt32(0)), E(:br_on_non_null, UInt32(0))]))
push!(cases, ("calls", "call 0 return_call 0 call_ref 1 return_call_ref 1 ref.func 0",
    [E(:call, UInt32(0)), E(:return_call, UInt32(0)), E(:call_ref, UInt32(1)),
     E(:return_call_ref, UInt32(1)), E(:ref_func, UInt32(0))]))

for (name, watbody, expected) in cases
    wat = PRE * "    " * watbody * "\n" * POST
    code, bytes, err = run_wt(["parse"], Vector{UInt8}(wat))
    if code != 0
        push!(issues, "$name: wasm-tools parse failed (harness?): $(first(split(err, '\n')))")
        continue
    end
    bytes = Vector{UInt8}(bytes)
    m = try
        decode(bytes)
    catch e
        push!(issues, "$name: decode threw $(sprint(showerror, e))")
        continue
    end
    body = m.funcs[1].body
    if expected !== nothing && body != expected
        push!(issues, "$name: decoded body mismatch:\n  expected $expected\n  got      $body")
        continue
    end
    re = try
        encode(m)
    catch e
        push!(issues, "$name: re-encode threw $(sprint(showerror, e))")
        continue
    end
    re = strip_datacount(re)
    bytes = strip_datacount(bytes)
    if re != bytes
        # find first differing byte for the report
        n = min(length(re), length(bytes))
        d = findfirst(i -> re[i] != bytes[i], 1:n)
        d = d === nothing ? n + 1 : d
        push!(issues, "$name: re-encoded bytes differ from wasm-tools at byte $d (len $(length(re)) vs $(length(bytes)))\n  ours:  $(bytes2hex(re))\n  theirs:$(bytes2hex(bytes))")
        continue
    end
    global ok += 1
end

println("=== PHASE 2 RESULTS ===")
println("passed: $ok / $(length(cases))")
for i in issues
    println("ISSUE: ", i)
end
