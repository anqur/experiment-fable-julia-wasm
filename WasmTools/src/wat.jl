# Minimal WebAssembly text format printer (flat instructions, numeric indices).
# Intended for debugging; `wasm-tools print` remains the reference printer.

const _REFTYPE_SHORTHANDS = Dict(
    FuncHT.code => "funcref", ExternHT.code => "externref", AnyHT.code => "anyref",
    EqHT.code => "eqref", I31HT.code => "i31ref", StructHT.code => "structref",
    ArrayHT.code => "arrayref", NoneHT.code => "nullref",
    NoFuncHT.code => "nullfuncref", NoExternHT.code => "nullexternref",
    ExnHT.code => "exnref", NoExnHT.code => "nullexnref",
)

heaptype_str(ht::HeapType) =
    isconcrete(ht) ? string(ht.code) : ABSTRACT_HEAPTYPE_NAMES[ht.code]

function valtype_str(t::NumType)
    t == I32 ? "i32" : t == I64 ? "i64" : t == F32 ? "f32" :
    t == F64 ? "f64" : "v128"
end
valtype_str(t::PackedType) = t == I8 ? "i8" : "i16"
function valtype_str(t::RefType)
    if t.nullable && !isconcrete(t.ht)
        return _REFTYPE_SHORTHANDS[t.ht.code]
    end
    return string("(ref ", t.nullable ? "null " : "", heaptype_str(t.ht), ")")
end

fieldtype_str(ft::FieldType) =
    ft.mut ? string("(mut ", valtype_str(ft.type), ")") : valtype_str(ft.type)

function comptype_str(ct::FuncType)
    s = "(func"
    isempty(ct.params) || (s *= string(" (param ", join(valtype_str.(ct.params), " "), ")"))
    isempty(ct.results) || (s *= string(" (result ", join(valtype_str.(ct.results), " "), ")"))
    return s * ")"
end
comptype_str(ct::StructType) =
    string("(struct", isempty(ct.fields) ? "" : " " *
        join(("(field $(fieldtype_str(f)))" for f in ct.fields), " "), ")")
comptype_str(ct::ArrayType) = string("(array ", fieldtype_str(ct.elem), ")")

function subtype_str(st::SubType)
    if st.final && isempty(st.supers)
        return comptype_str(st.comp)
    end
    return string("(sub ", st.final ? "final " : "",
                  join(string.(st.supers), " "), isempty(st.supers) ? "" : " ",
                  comptype_str(st.comp), ")")
end

function _float_str(x::Union{Float32,Float64})
    isnan(x) && return "nan"
    isinf(x) && return x > 0 ? "inf" : "-inf"
    return string(x)
end

function imm_str(m::WasmModule, kind::Symbol, x)
    kind === :u32 && return string(x)
    kind === :u32vec && return join(string.(x), " ")
    (kind === :i32 || kind === :i64) && return string(x)
    (kind === :f32 || kind === :f64) && return _float_str(x)
    if kind === :memarg
        ma = x::MemArg
        s = String[]
        ma.memidx != 0 && push!(s, string(ma.memidx))
        ma.offset != 0 && push!(s, "offset=$(ma.offset)")
        push!(s, "align=$(1 << ma.align)")
        return join(s, " ")
    end
    if kind === :blocktype
        x === nothing && return ""
        x isa ValType && return string("(result ", valtype_str(x), ")")
        return string("(type ", x, ")")
    end
    kind === :heaptype && return heaptype_str(x isa HeapType ? x : HeapType(x))
    kind === :reftype && return valtype_str(x)
    kind === :valtypevec && return string("(result ", join(valtype_str.(x), " "), ")")
    kind === :u8 && return string(x)
    if kind === :catchvec
        names = ("catch", "catch_ref", "catch_all", "catch_all_ref")
        return join((c.kind < 2 ? "($(names[c.kind+1]) $(c.tag) $(c.label))" :
                     "($(names[c.kind+1]) $(c.label))" for c in x), " ")
    end
    return string(x)
end

function inst_str(m::WasmModule, inst::Inst)
    spec = opspec(inst.op)
    parts = [spec.wat]
    if inst.op === :ref_test_null || inst.op === :ref_cast_null
        push!(parts, string("(ref null ", heaptype_str(inst.imm[1] isa HeapType ?
            inst.imm[1] : HeapType(inst.imm[1])), ")"))
    elseif inst.op === :ref_test || inst.op === :ref_cast
        push!(parts, string("(ref ", heaptype_str(inst.imm[1] isa HeapType ?
            inst.imm[1] : HeapType(inst.imm[1])), ")"))
    elseif inst.op === :br_on_cast || inst.op === :br_on_cast_fail
        flags, label, ht1, ht2 = inst.imm
        push!(parts, string(label))
        push!(parts, string("(ref ", (flags & 0x01) != 0 ? "null " : "", heaptype_str(ht1), ")"))
        push!(parts, string("(ref ", (flags & 0x02) != 0 ? "null " : "", heaptype_str(ht2), ")"))
    else
        for (kind, x) in zip(spec.imm, inst.imm)
            s = imm_str(m, kind, x)
            isempty(s) || push!(parts, s)
        end
    end
    return join(parts, " ")
end

function print_body(io::IO, m::WasmModule, body::Vector{Inst}, indent::String)
    level = 1
    for inst in body
        op = inst.op
        (op === Symbol("end") || op === Symbol("else")) && (level = max(level - 1, 0))
        println(io, indent, "  "^level, inst_str(m, inst))
        (op === :block || op === :loop || op === Symbol("if") ||
         op === Symbol("else") || op === :try_table) && (level += 1)
    end
end

"""
    print_wat(io, m::WasmModule)

Print a module in WebAssembly text format (flat instruction style, numeric
indices). Best-effort, intended for debugging.
"""
function print_wat(io::IO, m::WasmModule)
    println(io, "(module")
    idx = 0
    for rg in m.types
        grouped = length(rg.types) > 1
        grouped && println(io, "  (rec")
        pre = grouped ? "    " : "  "
        for st in rg.types
            println(io, pre, "(type (;$idx;) ", subtype_str(st), ")")
            idx += 1
        end
        grouped && println(io, "  )")
    end
    for im in m.imports
        d = im.desc
        desc = d isa FuncDesc ? "(func (type $(d.typeidx)))" :
               d isa TableType ? "(table $(valtype_str(d.reftype)) ...)" :
               d isa MemoryType ? "(memory $(d.limits.min))" :
               d isa GlobalType ? string("(global ", d.mut ? "(mut $(valtype_str(d.type)))" : valtype_str(d.type), ")") :
               "(tag (type $(d.typeidx)))"
        println(io, "  (import ", repr(im.mod), " ", repr(im.name), " ", desc, ")")
    end
    for (i, t) in enumerate(m.tables)
        println(io, "  (table (;$(numimports(m, TableType) + i - 1);) ",
                t.type.limits.min, " ",
                t.type.limits.max === nothing ? "" : string(t.type.limits.max, " "),
                valtype_str(t.type.reftype), ")")
    end
    for (i, mem) in enumerate(m.mems)
        println(io, "  (memory (;$(numimports(m, MemoryType) + i - 1);) ", mem.limits.min,
                mem.limits.max === nothing ? "" : " $(mem.limits.max)", ")")
    end
    for (i, g) in enumerate(m.globals)
        init = join((inst_str(m, inst) for inst in g.init), " ")
        println(io, "  (global (;$(numimports(m, GlobalType) + i - 1);) ",
                g.type.mut ? "(mut $(valtype_str(g.type.type)))" : valtype_str(g.type.type),
                " (", init, "))")
    end
    nimp = numfuncimports(m)
    for (i, f) in enumerate(m.funcs)
        fidx = nimp + i - 1
        ft = getfunctype(m, f.typeidx)
        print(io, "  (func ")
        f.name !== nothing && print(io, "\$", f.name, " ")
        print(io, "(;$fidx;) (type $(f.typeidx))")
        isempty(ft.params) || print(io, " (param ", join(valtype_str.(ft.params), " "), ")")
        isempty(ft.results) || print(io, " (result ", join(valtype_str.(ft.results), " "), ")")
        println(io)
        isempty(f.locals) || println(io, "    (local ", join(valtype_str.(f.locals), " "), ")")
        print_body(io, m, f.body, "  ")
        println(io, "  )")
    end
    for e in m.exports
        println(io, "  (export ", repr(e.name), " (", e.kind === :memory ? "memory" : e.kind,
                " ", e.idx, "))")
    end
    m.start === nothing || println(io, "  (start ", m.start, ")")
    for e in m.elems
        print(io, "  (elem ")
        if e.mode === :active
            e.tableidx != 0 && print(io, "(table ", e.tableidx, ") ")
            print(io, "(offset ", join((inst_str(m, i) for i in e.offset), " "), ") ")
        elseif e.mode === :declarative
            print(io, "declare ")
        end
        print(io, valtype_str(e.reftype))
        for expr in e.init
            print(io, " (item ", join((inst_str(m, i) for i in expr), " "), ")")
        end
        println(io, ")")
    end
    for d in m.datas
        print(io, "  (data ")
        if d.mode === :active
            d.memidx != 0 && print(io, "(memory ", d.memidx, ") ")
            print(io, "(offset ", join((inst_str(m, i) for i in d.offset), " "), ") ")
        end
        println(io, repr(String(copy(d.bytes))), ")")
    end
    println(io, ")")
end

"""String form of [`print_wat`](@ref)."""
wat(m::WasmModule) = sprint(print_wat, m)
