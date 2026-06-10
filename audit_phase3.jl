# Phase 3: type-system byte constants (rec/sub/comptype prefixes, packed types,
# reftype encodings, abstract heap types, limits flags) via wat round-trips.
using WasmTools
using WasmTools: decode, encode, RecGroup, SubType, FuncType, StructType, ArrayType,
                 FieldType, I8, I16, I32, I64, F32, F64, V128, RefType, HeapType,
                 FuncHT, ExternHT, AnyHT, EqHT, I31HT, StructHT, ArrayHT, ExnHT,
                 NoneHT, NoFuncHT, NoExternHT, NoExnHT, flattypes

const WT = "/workspace/tools/wasm-tools-dist/wasm-tools"

function run_wt(args::Vector{String}, input::Vector{UInt8})
    inbuf = IOBuffer(input)
    out = IOBuffer(); err = IOBuffer()
    p = run(pipeline(ignorestatus(`$WT $args -`), stdin=inbuf, stdout=out, stderr=err); wait=true)
    return p.exitcode, take!(out), String(take!(err))
end

function strip_datacount(bytes::Vector{UInt8})
    io = IOBuffer(bytes); out = IOBuffer()
    write(out, read(io, 8))
    while !eof(io)
        sid = read(io, UInt8)
        size = WasmTools.read_uleb(io, 32)
        payload = read(io, size)
        sid == 12 && continue
        sid == 0 && startswith(String(copy(payload)), "\x04name") && continue
        write(out, sid); WasmTools.write_uleb(out, length(payload)); write(out, payload)
    end
    return take!(out)
end

issues = String[]
ok = 0

function check(name::String, wat::String, structural=nothing; validate::Bool=true)
    global ok
    code, bytes, err = run_wt(["parse"], Vector{UInt8}(wat))
    if code != 0
        push!(issues, "$name: harness wat parse failed: $(first(split(err,'\n')))")
        return
    end
    bytes = Vector{UInt8}(bytes)
    if validate
        vcode, _, verr = run_wt(["validate", "--features", "all"], bytes)
        vcode == 0 || (push!(issues, "$name: harness wat does not validate: $(first(split(verr,'\n')))"); return)
    end
    m = try
        decode(bytes)
    catch e
        push!(issues, "$name: decode threw $(sprint(showerror, e))")
        return
    end
    if structural !== nothing
        sres = try
            structural(m)
        catch e
            "structural check threw $(sprint(showerror, e))"
        end
        if sres !== true
            push!(issues, "$name: structural mismatch: $sres")
            return
        end
    end
    re = try
        encode(m)
    catch e
        push!(issues, "$name: re-encode threw $(sprint(showerror, e))")
        return
    end
    if strip_datacount(re) != strip_datacount(bytes)
        push!(issues, "$name: bytes differ.\n  ours:  $(bytes2hex(re))\n  theirs:$(bytes2hex(bytes))")
        return
    end
    # also: our bytes must print cleanly
    pc2, w2, _ = run_wt(["print"], re)
    if pc2 != 0
        push!(issues, "$name: wasm-tools cannot print our re-encoding")
        return
    end
    ok += 1
end

# rec group with two mutually recursive types (0x4E) + sub non-final (0x50)
check("rec group + sub open", """
(module
  (rec
    (type \$a (sub (struct (field (ref null \$b)))))
    (type \$b (sub (struct (field (ref null \$a))))))
)
""", m -> begin
    length(m.types) == 1 || return "expected 1 recgroup, got $(length(m.types))"
    rg = m.types[1]
    length(rg.types) == 2 || return "expected 2 types in group"
    st = rg.types[1]
    st.final == false || return "expected non-final"
    isempty(st.supers) || return "expected no supers"
    st.comp isa StructType || return "expected struct"
    st.comp.fields[1].type == RefType(true, HeapType(1)) || return "field type wrong: $(st.comp.fields[1])"
    true
end)

# sub with supertype, sub final with supertype (0x50 / 0x4F with supers)
check("sub chain final/open", """
(module
  (type \$base (sub (struct (field i32))))
  (type \$mid (sub \$base (struct (field i32) (field i64))))
  (type \$leaf (sub final \$mid (struct (field i32) (field i64) (field f32))))
)
""", m -> begin
    ts = flattypes(m)
    ts[1].final == false && isempty(ts[1].supers) || return "base wrong: $(ts[1])"
    ts[2].final == false && ts[2].supers == UInt32[0] || return "mid wrong: $(ts[2])"
    ts[3].final == true && ts[3].supers == UInt32[1] || return "leaf wrong: $(ts[3])"
    true
end)

# packed types + mutability (0x78 i8 / 0x77 i16)
check("packed struct fields", """
(module
  (type (struct (field i8) (field (mut i8)) (field i16) (field (mut i16)) (field (mut f64))))
  (type (array (mut i8)))
  (type (array i16))
)
""", m -> begin
    ts = flattypes(m)
    f = ts[1].comp.fields
    f[1] == FieldType(I8, false) || return "f1 $(f[1])"
    f[2] == FieldType(I8, true)  || return "f2 $(f[2])"
    f[3] == FieldType(I16, false) || return "f3 $(f[3])"
    f[4] == FieldType(I16, true) || return "f4 $(f[4])"
    f[5] == FieldType(F64, true) || return "f5 $(f[5])"
    ts[2].comp == ArrayType(FieldType(I8, true)) || return "array1 $(ts[2].comp)"
    ts[3].comp == ArrayType(FieldType(I16, false)) || return "array2 $(ts[3].comp)"
    true
end)

# every abstract heaptype as global valtype shorthand + explicit (ref null X)/(ref X)
let names = ["funcref", "externref", "anyref", "eqref", "i31ref", "structref",
             "arrayref", "exnref", "nullref", "nullfuncref", "nullexternref", "nullexnref"],
    hts = [FuncHT, ExternHT, AnyHT, EqHT, I31HT, StructHT, ArrayHT, ExnHT,
           NoneHT, NoFuncHT, NoExternHT, NoExnHT]
    globals = join(["  (global $n (ref.null $(replace(n=="nullref" ? "none" : n=="nullfuncref" ? "nofunc" : n=="nullexternref" ? "noextern" : n=="nullexnref" ? "noexn" : replace(n, "ref"=>""), "null"=>"no"))))" for n in names], "\n")
    # simpler: write explicitly
    wat = """
(module
  (global funcref (ref.null func))
  (global externref (ref.null extern))
  (global anyref (ref.null any))
  (global eqref (ref.null eq))
  (global i31ref (ref.null i31))
  (global structref (ref.null struct))
  (global arrayref (ref.null array))
  (global exnref (ref.null exn))
  (global nullref (ref.null none))
  (global nullfuncref (ref.null nofunc))
  (global nullexternref (ref.null noextern))
  (global nullexnref (ref.null noexn))
)
"""
    check("abstract heaptype shorthands", wat, m -> begin
        for (i, ht) in enumerate(hts)
            m.globals[i].type.type == RefType(true, ht) || return "global $i: $(m.globals[i].type.type) != ref null $(ht)"
            m.globals[i].init == [WasmTools.Inst(:ref_null, ht)] || return "init $i wrong: $(m.globals[i].init)"
        end
        true
    end)
end

# non-null + concrete reftypes in globals/locals/params (0x63/0x64)
check("explicit ref null / ref bytes", """
(module
  (type \$s (struct))
  (global (ref null \$s) (ref.null \$s))
  (global (mut (ref null any)) (ref.null any))
  (func (param (ref \$s)) (result (ref \$s)) (local (ref null \$s)) local.get 0)
  (func (param (ref any)) (ref.null \$s) drop)
)
""", m -> begin
    m.globals[1].type.type == RefType(true, HeapType(0)) || return "g1 $(m.globals[1].type)"
    m.globals[2].type.type == RefType(true, AnyHT) && m.globals[2].type.mut || return "g2 $(m.globals[2].type)"
    ft = WasmTools.getfunctype(m, Int(m.funcs[1].typeidx))
    ft.params[1] == RefType(false, HeapType(0)) || return "param $(ft.params)"
    ft.results[1] == RefType(false, HeapType(0)) || return "result $(ft.results)"
    m.funcs[1].locals[1] == RefType(true, HeapType(0)) || return "local $(m.funcs[1].locals)"
    true
end)

# v128 valtype byte (0x7B): decode/encode only, validation needs simd feature anyway
check("v128 local", """
(module (func (local v128)))
""", m -> m.funcs[1].locals[1] == V128 || "local $(m.funcs[1].locals)")

# limits flags: max, memory64, table64, shared? (threads excluded -> skip shared)
check("limits and memory64", """
(module
  (memory 1)
  (memory 1 5)
  (memory i64 2)
  (memory i64 2 9)
  (table 1 funcref)
  (table 2 7 externref)
  (table i64 3 8 funcref)
)
""", m -> begin
    l = [mem.limits for mem in m.mems]
    l[1].min == 1 && l[1].max === nothing && !l[1].idx64 || return "mem1 $(l[1])"
    l[2].max == 5 || return "mem2 $(l[2])"
    l[3].idx64 && l[3].min == 2 && l[3].max === nothing || return "mem3 $(l[3])"
    l[4].idx64 && l[4].max == 9 || return "mem4 $(l[4])"
    t = m.tables
    t[2].type.limits.max == 7 || return "t2 $(t[2])"
    t[3].type.limits.idx64 && t[3].type.limits.min == 3 || return "t3 $(t[3])"
    true
end)

# table with explicit init expr (0x40 0x00 form)
check("table init expr", """
(module
  (type \$s (struct))
  (table 1 (ref null \$s) (struct.new \$s))
)
""", m -> begin
    m.tables[1].init !== nothing || return "expected init expr"
    m.tables[1].init == [WasmTools.Inst(:struct_new, UInt32(0))] || return "init $(m.tables[1].init)"
    true
end)

# imports of every kind + tag attr + exports of every kind + start
check("imports/exports/tags/start", """
(module
  (import "a" "f" (func))
  (import "a" "t" (table 1 funcref))
  (import "a" "m" (memory 1))
  (import "a" "g" (global i32))
  (import "a" "e" (tag (param i32)))
  (func)
  (start 1)
  (table \$t2 1 funcref)
  (memory \$m2 1)
  (global \$g2 i64 (i64.const 1))
  (tag \$e2 (param i64))
  (export "f2" (func 1))
  (export "t2" (table 1))
  (export "m2" (memory 1))
  (export "g2" (global 1))
  (export "e2" (tag 1))
)
""", m -> begin
    length(m.imports) == 5 || return "imports $(length(m.imports))"
    m.imports[5].desc isa WasmTools.TagType || return "tag import $(m.imports[5])"
    length(m.exports) == 5 || return "exports"
    Set(e.kind for e in m.exports) == Set([:func,:table,:memory,:global,:tag]) || return "export kinds"
    m.start == 1 || return "start $(m.start)"
    length(m.tags) == 1 || return "tags $(length(m.tags))"
    true
end)

# elem segment variants (flags 0..7); use distinct tables/types so all forms appear
check("elem segment forms", """
(module
  (type \$s (struct))
  (table 5 funcref)
  (table 5 funcref)
  (table 5 (ref null \$s))
  (func)
  (elem (i32.const 0) func 0)
  (elem func 0)
  (elem (table 1) (i32.const 1) func 0)
  (elem declare func 0)
  (elem (i32.const 2) funcref (ref.null func) (ref.func 0))
  (elem funcref (ref.null func))
  (elem (table 2) (i32.const 0) (ref null \$s) (struct.new \$s))
  (elem declare funcref (ref.null func))
)
""", m -> begin
    e = m.elems
    length(e) == 8 || return "count"
    e[1].mode === :active && e[1].tableidx == 0 || return "e1"
    e[2].mode === :passive || return "e2"
    e[3].mode === :active && e[3].tableidx == 1 || return "e3"
    e[4].mode === :declarative || return "e4"
    e[5].init == [[WasmTools.Inst(:ref_null, FuncHT)], [WasmTools.Inst(:ref_func, UInt32(0))]] || return "e5 $(e[5].init)"
    e[7].reftype == RefType(true, HeapType(0)) || return "e7 $(e[7].reftype)"
    true
end)

# data segment variants incl. memidx 1
check("data segment forms", """
(module
  (memory 1)
  (memory 1)
  (data (i32.const 1) "xy")
  (data "passive")
  (data (memory 1) (i32.const 2) "z")
)
""", m -> begin
    d = m.datas
    d[1].mode === :active && d[1].memidx == 0 && d[1].bytes == b"xy" || return "d1"
    d[2].mode === :passive && d[2].bytes == b"passive" || return "d2"
    d[3].mode === :active && d[3].memidx == 1 && d[3].bytes == b"z" || return "d3"
    true
end)

# globals with extended-const style exprs and all const instrs
check("global init exprs", """
(module
  (global i32 (i32.const -5))
  (global i64 (i64.const -123456789))
  (global f32 (f32.const 1.25))
  (global f64 (f64.const -0.5))
  (global i32 (i32.add (i32.const 1) (i32.const 2)))
  (func)
  (global funcref (ref.func 0))
  (elem declare func 0)
)
""")

println("=== PHASE 3 RESULTS ===")
println("passed: $ok")
for i in issues
    println("ISSUE: ", i)
end
