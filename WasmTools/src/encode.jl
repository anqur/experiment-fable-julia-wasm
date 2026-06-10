# Binary encoding (module -> bytes).

struct MalformedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MalformedError) = print(io, "MalformedError: ", e.msg)

function write_name(io::IO, s::AbstractString)
    str = String(s)
    isvalid(String, str) ||
        throw(ArgumentError("name is not valid UTF-8: $(repr(str))"))
    write_uleb(io, ncodeunits(str))
    write(io, codeunits(str))
end

function write_vec(f, io::IO, v)
    write_uleb(io, length(v))
    foreach(x -> f(io, x), v)
end

# --- types ----------------------------------------------------------------

write_valtype(io::IO, t::NumType) = write(io, t.code)
write_storagetype(io::IO, t::PackedType) = write(io, t.code)
write_storagetype(io::IO, t::Union{NumType,RefType}) = write_valtype(io, t)

write_heaptype(io::IO, ht::HeapType) = write_sleb(io, ht.code)

function write_valtype(io::IO, t::RefType)
    if t.nullable && !isconcrete(t.ht)
        # shorthand: nullable abstract reftype is the single heap-type byte
        write(io, UInt8(t.ht.code & 0x7f))
    else
        write(io, t.nullable ? 0x63 : 0x64)
        write_heaptype(io, t.ht)
    end
end

function write_fieldtype(io::IO, ft::FieldType)
    write_storagetype(io, ft.type)
    write(io, UInt8(ft.mut))
end

function write_comptype(io::IO, ct::FuncType)
    write(io, 0x60)
    write_vec(write_valtype, io, ct.params)
    write_vec(write_valtype, io, ct.results)
end
function write_comptype(io::IO, ct::StructType)
    write(io, 0x5F)
    write_vec(write_fieldtype, io, ct.fields)
end
function write_comptype(io::IO, ct::ArrayType)
    write(io, 0x5E)
    write_fieldtype(io, ct.elem)
end

function write_subtype(io::IO, st::SubType)
    if st.final && isempty(st.supers)
        write_comptype(io, st.comp)
    else
        write(io, st.final ? 0x4F : 0x50)
        write_vec(write_uleb, io, st.supers)
        write_comptype(io, st.comp)
    end
end

function write_rectype(io::IO, rg::RecGroup)
    if length(rg.types) == 1
        write_subtype(io, rg.types[1])
    else
        write(io, 0x4E)
        write_vec(write_subtype, io, rg.types)
    end
end

function write_limits(io::IO, l::Limits)
    flags = UInt8(0)
    l.max === nothing || (flags |= 0x01)
    l.shared && (flags |= 0x02)
    l.idx64 && (flags |= 0x04)
    write(io, flags)
    write_uleb(io, l.min)
    l.max === nothing || write_uleb(io, l.max)
end

function write_tabletype(io::IO, tt::TableType)
    write_valtype(io, tt.reftype)
    write_limits(io, tt.limits)
end

function write_globaltype(io::IO, gt::GlobalType)
    write_valtype(io, gt.type)
    write(io, UInt8(gt.mut))
end

# --- instructions -----------------------------------------------------------

function write_blocktype(io::IO, bt::Nothing)
    write(io, 0x40)
end
write_blocktype(io::IO, bt::NumType) = write_valtype(io, bt)
# A reference-type result (including concrete and non-nullable refs) uses the
# valtype shorthand; 0x63/0x64 are negative as s33 first bytes, so this never
# collides with the non-negative s33 type-index form.
write_blocktype(io::IO, bt::RefType) = write_valtype(io, bt)
function write_blocktype(io::IO, bt::Integer)
    bt >= 0 || throw(ArgumentError("negative type index in block type"))
    write_sleb(io, Int64(bt))   # s33, non-negative
end

function write_memarg(io::IO, ma::MemArg)
    ma.align < 0x40 || throw(ArgumentError(
        "memarg alignment exponent must be < 64 (bit 6 of the flags is the multi-memory flag)"))
    if ma.memidx == 0
        write_uleb(io, ma.align)
    else
        write_uleb(io, ma.align | UInt32(1) << 6)
        write_uleb(io, ma.memidx)
    end
    write_uleb(io, ma.offset)
end
write_memarg(io::IO, x) = throw(ArgumentError("expected MemArg immediate, got $x"))

signed32(x::Integer) = x isa UInt32 ? reinterpret(Int32, x) : Int32(x)
signed64(x::Integer) = x isa UInt64 ? reinterpret(Int64, x) : Int64(x)

function write_imm(io::IO, kind::Symbol, x)
    if kind === :u32
        write_uleb(io, x::Integer)
    elseif kind === :u32vec
        write_vec(write_uleb, io, x)
    elseif kind === :i32
        write_sleb(io, signed32(x))
    elseif kind === :i64
        write_sleb(io, signed64(x))
    elseif kind === :f32
        write(io, htol(reinterpret(UInt32, Float32(x))))
    elseif kind === :f64
        write(io, htol(reinterpret(UInt64, Float64(x))))
    elseif kind === :memarg
        write_memarg(io, x)
    elseif kind === :blocktype
        write_blocktype(io, x)
    elseif kind === :heaptype
        write_heaptype(io, x isa HeapType ? x : HeapType(x))
    elseif kind === :valtypevec
        write_vec(write_valtype, io, x)
    elseif kind === :u8
        write(io, UInt8(x))
    elseif kind === :catchvec
        write_vec(io, x) do io, c::Catch
            write(io, c.kind)
            c.kind < 2 && write_uleb(io, c.tag)
            write_uleb(io, c.label)
        end
    else
        error("unknown immediate kind $kind")
    end
end

function write_inst(io::IO, inst::Inst)
    spec = opspec(inst.op)
    write(io, spec.prefix)
    spec.sub >= 0 && write_uleb(io, spec.sub)
    length(inst.imm) == length(spec.imm) ||
        throw(ArgumentError("$(inst.op) expects $(length(spec.imm)) immediates, got $(length(inst.imm))"))
    for (kind, x) in zip(spec.imm, inst.imm)
        write_imm(io, kind, x)
    end
end

"""Write an expression (instruction sequence) followed by the terminating `end`."""
function write_expr(io::IO, insts::Vector{Inst})
    foreach(i -> write_inst(io, i), insts)
    write(io, 0x0B)
end

# --- sections ---------------------------------------------------------------

function write_section(f, io::IO, id::Integer)
    buf = IOBuffer()
    f(buf)
    data = take!(buf)
    write(io, UInt8(id))
    write_uleb(io, length(data))
    write(io, data)
end

function write_importdesc(io::IO, d::FuncDesc)
    write(io, 0x00); write_uleb(io, d.typeidx)
end
function write_importdesc(io::IO, d::TableType)
    write(io, 0x01); write_tabletype(io, d)
end
function write_importdesc(io::IO, d::MemoryType)
    write(io, 0x02); write_limits(io, d.limits)
end
function write_importdesc(io::IO, d::GlobalType)
    write(io, 0x03); write_globaltype(io, d)
end
function write_importdesc(io::IO, d::TagType)
    write(io, 0x04); write(io, 0x00); write_uleb(io, d.typeidx)
end

const EXPORT_KINDS = Dict(:func => 0x00, :table => 0x01, :memory => 0x02,
                          :global => 0x03, :tag => 0x04)

"""Return the funcidx if `expr` is exactly `ref.func k`, else `nothing`."""
function _as_funcidx(expr::Vector{Inst})
    length(expr) == 1 && expr[1].op === :ref_func || return nothing
    return UInt32(expr[1].imm[1])
end

function write_elem(io::IO, e::Elem)
    e.mode in (:active, :passive, :declarative) ||
        throw(ArgumentError("bad elem mode $(e.mode)"))
    funcidxs = [_as_funcidx(expr) for expr in e.init]
    # Honor the recorded binary flavor (set by `read_elem`) so foreign modules
    # re-encode byte-identically; hand-built segments default to compact.
    compact = !e.exprform && e.reftype == FuncRefT && !any(isnothing, funcidxs)
    explicit_table = e.mode === :active && (e.tableidx != 0 || e.explicit_tableidx)
    if compact
        if e.mode === :active && !explicit_table
            write_uleb(io, 0)
            write_expr(io, e.offset)
            write_vec(write_uleb, io, funcidxs)
        elseif e.mode === :active
            write_uleb(io, 2)
            write_uleb(io, e.tableidx)
            write_expr(io, e.offset)
            write(io, 0x00)   # elemkind: funcref
            write_vec(write_uleb, io, funcidxs)
        else
            write_uleb(io, e.mode === :passive ? 1 : 3)
            write(io, 0x00)
            write_vec(write_uleb, io, funcidxs)
        end
    else
        if e.mode === :active && !explicit_table && e.reftype == FuncRefT
            write_uleb(io, 4)
            write_expr(io, e.offset)
            write_vec(write_expr, io, e.init)
        elseif e.mode === :active
            write_uleb(io, 6)
            write_uleb(io, e.tableidx)
            write_expr(io, e.offset)
            write_valtype(io, e.reftype)
            write_vec(write_expr, io, e.init)
        else
            write_uleb(io, e.mode === :passive ? 5 : 7)
            write_valtype(io, e.reftype)
            write_vec(write_expr, io, e.init)
        end
    end
end

function write_data(io::IO, d::Data)
    if d.mode === :active && d.memidx == 0
        write_uleb(io, 0)
        write_expr(io, d.offset)
    elseif d.mode === :active
        write_uleb(io, 2)
        write_uleb(io, d.memidx)
        write_expr(io, d.offset)
    elseif d.mode === :passive
        write_uleb(io, 1)
    else
        throw(ArgumentError("bad data mode $(d.mode)"))
    end
    write_uleb(io, length(d.bytes))
    write(io, d.bytes)
end

function write_code(io::IO, f::Func)
    buf = IOBuffer()
    # compress locals into runs of equal types
    runs = Tuple{UInt32,ValType}[]
    for t in f.locals
        if !isempty(runs) && runs[end][2] == t
            runs[end] = (runs[end][1] + 1, t)
        else
            push!(runs, (UInt32(1), t))
        end
    end
    write_vec(buf, runs) do io, (count, t)
        write_uleb(io, count)
        write_valtype(io, t)
    end
    write_expr(buf, f.body)
    data = take!(buf)
    write_uleb(io, length(data))
    write(io, data)
end

function write_name_section(io::IO, m::WasmModule)
    nimports = numfuncimports(m)
    # Imported-function names (m.funcnames) followed by defined-function names,
    # in function-index order as the name section requires.
    named = Tuple{UInt32,String}[(idx, name) for (idx, name) in m.funcnames
                                 if Int(idx) < nimports]
    append!(named, ((UInt32(nimports + i - 1), f.name)
                    for (i, f) in enumerate(m.funcs) if f.name !== nothing))
    sort!(named; by=first)
    isempty(named) && return
    buf = IOBuffer()
    write_name(buf, "name")
    sub = IOBuffer()
    write_vec(sub, named) do io, (idx, name)
        write_uleb(io, idx)
        write_name(io, name)
    end
    subdata = take!(sub)
    write(buf, UInt8(1))   # function-names subsection
    write_uleb(buf, length(subdata))
    write(buf, subdata)
    data = take!(buf)
    write(io, UInt8(0))
    write_uleb(io, length(data))
    write(io, data)
end

"""
    encode(m::WasmModule) -> Vector{UInt8}

Serialize a module to wasm binary format.
"""
function encode(m::WasmModule)
    io = IOBuffer()
    write(io, UInt8[0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
    isempty(m.types) || write_section(io, 1) do s
        write_vec(write_rectype, s, m.types)
    end
    isempty(m.imports) || write_section(io, 2) do s
        write_vec(s, m.imports) do io, im
            write_name(io, im.mod)
            write_name(io, im.name)
            write_importdesc(io, im.desc)
        end
    end
    isempty(m.funcs) || write_section(io, 3) do s
        write_vec(s, m.funcs) do io, f
            write_uleb(io, f.typeidx)
        end
    end
    isempty(m.tables) || write_section(io, 4) do s
        write_vec(s, m.tables) do io, t
            if t.init === nothing
                write_tabletype(io, t.type)
            else
                write(io, 0x40); write(io, 0x00)
                write_tabletype(io, t.type)
                write_expr(io, t.init)
            end
        end
    end
    isempty(m.mems) || write_section(io, 5) do s
        write_vec(s, m.mems) do io, mem
            write_limits(io, mem.limits)
        end
    end
    isempty(m.tags) || write_section(io, 13) do s
        write_vec(s, m.tags) do io, t
            write(io, 0x00)
            write_uleb(io, t.typeidx)
        end
    end
    isempty(m.globals) || write_section(io, 6) do s
        write_vec(s, m.globals) do io, g
            write_globaltype(io, g.type)
            write_expr(io, g.init)
        end
    end
    isempty(m.exports) || write_section(io, 7) do s
        write_vec(s, m.exports) do io, e
            write_name(io, e.name)
            write(io, EXPORT_KINDS[e.kind])
            write_uleb(io, e.idx)
        end
    end
    m.start === nothing || write_section(io, 8) do s
        write_uleb(s, m.start)
    end
    isempty(m.elems) || write_section(io, 9) do s
        write_vec(write_elem, s, m.elems)
    end
    isempty(m.datas) || write_section(io, 12) do s
        write_uleb(s, length(m.datas))
    end
    isempty(m.funcs) || write_section(io, 10) do s
        write_vec(write_code, s, m.funcs)
    end
    isempty(m.datas) || write_section(io, 11) do s
        write_vec(write_data, s, m.datas)
    end
    write_name_section(io, m)
    for c in m.customs
        write_section(io, 0) do s
            write_name(s, c.name)
            write(s, c.bytes)
        end
    end
    return take!(io)
end
