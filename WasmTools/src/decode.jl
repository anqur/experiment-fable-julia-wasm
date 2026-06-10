# Binary decoding (bytes -> module).

function read_name_str(io::IO)
    len = read_uleb(io, 32)
    bytes = read(io, len)
    length(bytes) == len || throw(MalformedError("truncated name"))
    isvalid(String, bytes) || throw(MalformedError("malformed UTF-8 name"))
    return String(bytes)
end

function read_vec(f, io::IO)
    n = read_uleb(io, 32)
    return [f(io) for _ in 1:n]
end

const _NUMTYPE_BYTES = (0x7F, 0x7E, 0x7D, 0x7C, 0x7B)
const _ABSHT_BYTES = (0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74)

function read_heaptype(io::IO)
    code = read_s33(io)
    code >= 0 || haskey(ABSTRACT_HEAPTYPE_NAMES, code) ||
        throw(MalformedError("invalid heap type $code"))
    return HeapType(code)
end

"""Finish reading a valtype whose first byte `b` has been consumed."""
function read_valtype_first(io::IO, b::UInt8)
    b in _NUMTYPE_BYTES && return NumType(b)
    b == 0x63 && return RefType(true, read_heaptype(io))
    b == 0x64 && return RefType(false, read_heaptype(io))
    b in _ABSHT_BYTES && return RefType(true, HeapType(Int64(b) - 0x80))
    throw(MalformedError("invalid value type byte 0x$(string(b, base=16))"))
end
read_valtype(io::IO) = read_valtype_first(io, read(io, UInt8))

function read_storagetype(io::IO)
    b = read(io, UInt8)
    (b == 0x78 || b == 0x77) && return PackedType(b)
    return read_valtype_first(io, b)
end

read_fieldtype(io::IO) = FieldType(read_storagetype(io), read(io, UInt8) != 0)

function read_comptype(io::IO, b::UInt8)
    if b == 0x60
        params = read_vec(read_valtype, io)
        results = read_vec(read_valtype, io)
        return FuncType(params, results)
    elseif b == 0x5F
        return StructType(read_vec(read_fieldtype, io))
    elseif b == 0x5E
        return ArrayType(read_fieldtype(io))
    end
    throw(MalformedError("invalid composite type byte 0x$(string(b, base=16))"))
end

function read_subtype(io::IO, b::UInt8=read(io, UInt8))
    if b == 0x50 || b == 0x4F
        supers = read_vec(read_u32, io)
        comp = read_comptype(io, read(io, UInt8))
        return SubType(b == 0x4F, supers, comp)
    end
    return SubType(true, UInt32[], read_comptype(io, b))
end

function read_rectype(io::IO)
    b = read(io, UInt8)
    b == 0x4E && return RecGroup(read_vec(read_subtype, io))
    return RecGroup([read_subtype(io, b)])
end

function read_limits(io::IO)
    flags = read(io, UInt8)
    flags & ~UInt8(0x07) == 0 || throw(MalformedError("invalid limits flags"))
    min = read_uleb(io, 64)
    max = (flags & 0x01) != 0 ? read_uleb(io, 64) : nothing
    return Limits(min, max, (flags & 0x02) != 0, (flags & 0x04) != 0)
end

read_tabletype(io::IO) = begin
    rt = read_valtype(io)
    rt isa RefType || throw(MalformedError("table element type must be a reftype"))
    TableType(rt, read_limits(io))
end

read_globaltype(io::IO) = GlobalType(read_valtype(io), read(io, UInt8) != 0)

function read_blocktype(io::IO)
    b = read(io, UInt8)
    b == 0x40 && return nothing
    (b in _NUMTYPE_BYTES || b in _ABSHT_BYTES || b == 0x63 || b == 0x64) &&
        return read_valtype_first(io, b)
    idx = read_sleb_first(io, b, 33)
    idx >= 0 || throw(MalformedError("invalid block type"))
    return idx
end

function read_memarg(io::IO)
    align = read_u32(io)
    align < 0x80 || throw(MalformedError("malformed memarg alignment flags"))
    memidx = UInt32(0)
    if align & (UInt32(1) << 6) != 0
        align &= ~(UInt32(1) << 6)
        memidx = read_u32(io)
    end
    offset = read_uleb(io, 64)
    return MemArg(align, offset, memidx)
end

function read_imm(io::IO, kind::Symbol)
    kind === :u32 && return read_u32(io)
    kind === :u32vec && return read_vec(read_u32, io)
    kind === :i32 && return Int32(read_sleb(io, 32))
    kind === :i64 && return read_sleb(io, 64)
    kind === :f32 && return reinterpret(Float32, ltoh(read(io, UInt32)))
    kind === :f64 && return reinterpret(Float64, ltoh(read(io, UInt64)))
    kind === :memarg && return read_memarg(io)
    kind === :blocktype && return read_blocktype(io)
    kind === :heaptype && return read_heaptype(io)
    kind === :valtypevec && return read_vec(read_valtype, io)
    kind === :u8 && return read(io, UInt8)
    kind === :catchvec && return read_vec(io) do io
        k = read(io, UInt8)
        k <= 3 || throw(MalformedError("invalid catch clause kind"))
        tag = k < 2 ? read_u32(io) : UInt32(0)
        Catch(k, tag, read_u32(io))
    end
    error("unknown immediate kind $kind")
end

function read_inst(io::IO)
    b = read(io, UInt8)
    if b == 0xFB || b == 0xFC || b == 0xFD
        sub = read_u32(io)
        spec = get(DECODE_PREFIXED, (b, sub), nothing)
        spec === nothing && throw(MalformedError(
            "unsupported opcode 0x$(string(b, base=16)) $(sub)"))
    else
        spec = DECODE_SINGLE[Int(b)+1]
        spec === nothing && throw(MalformedError(
            "unsupported opcode 0x$(string(b, base=16))"))
    end
    isempty(spec.imm) && return Inst(spec.op)
    return Inst(spec.op, Tuple(read_imm(io, kind) for kind in spec.imm))
end

"""Read instructions until the matching `end` (which is consumed, not stored)."""
function read_expr(io::IO)
    insts = Inst[]
    depth = 0
    while true
        inst = read_inst(io)
        op = inst.op
        if op === :block || op === :loop || op === Symbol("if") || op === :try_table
            depth += 1
        elseif op === Symbol("end")
            depth == 0 && return insts
            depth -= 1
        end
        push!(insts, inst)
    end
end

# --- sections ---------------------------------------------------------------

function read_importdesc(io::IO)
    kind = read(io, UInt8)
    kind == 0x00 && return FuncDesc(read_u32(io))
    kind == 0x01 && return read_tabletype(io)
    kind == 0x02 && return MemoryType(read_limits(io))
    kind == 0x03 && return read_globaltype(io)
    if kind == 0x04
        read(io, UInt8) == 0x00 || throw(MalformedError("invalid tag attribute"))
        return TagType(read_u32(io))
    end
    throw(MalformedError("invalid import kind $kind"))
end

const EXPORT_KINDS_REV = Dict(v => k for (k, v) in EXPORT_KINDS)

function read_elem(io::IO)
    flag = read_u32(io)
    flag <= 7 || throw(MalformedError("invalid element segment flag $flag"))
    mode = (flag & 0x01) == 0 ? :active : ((flag & 0x02) == 0 ? :passive : :declarative)
    tableidx = UInt32(0)
    offset = Inst[]
    if mode === :active
        (flag & 0x02) != 0 && (tableidx = read_u32(io))
        offset = read_expr(io)
    end
    reftype = FuncRefT
    if (flag & 0x04) == 0
        # compact funcidx form
        if flag in (1, 2, 3)
            read(io, UInt8) == 0x00 || throw(MalformedError("invalid elemkind"))
        end
        funcs = read_vec(read_u32, io)
        init = Vector{Inst}[Inst[Inst(:ref_func, f)] for f in funcs]
    else
        if flag in (5, 6, 7)
            rt = read_valtype(io)
            rt isa RefType || throw(MalformedError("element type must be a reftype"))
            reftype = rt
        end
        init = read_vec(read_expr, io)
    end
    return Elem(mode, tableidx, offset, reftype, init,
                (flag & 0x04) != 0,                       # exprform
                mode === :active && (flag & 0x02) != 0)   # explicit_tableidx
end

function read_data(io::IO)
    flag = read_u32(io)
    if flag == 0
        d = Data(:active, UInt32(0), read_expr(io), UInt8[])
    elseif flag == 1
        d = Data(:passive, UInt32(0), Inst[], UInt8[])
    elseif flag == 2
        memidx = read_u32(io)
        d = Data(:active, memidx, read_expr(io), UInt8[])
    else
        throw(MalformedError("invalid data segment flag $flag"))
    end
    len = read_uleb(io, 32)
    bytes = read(io, len)
    length(bytes) == len || throw(MalformedError("truncated data segment"))
    return Data(d.mode, d.memidx, d.offset, bytes)
end

function read_code!(io::IO, f::Func)
    size = read_uleb(io, 32)
    body = read(io, size)
    length(body) == size || throw(MalformedError("truncated code entry"))
    bio = IOBuffer(body)
    nruns = read_uleb(bio, 32)
    locals = ValType[]
    for _ in 1:nruns
        count = read_uleb(bio, 32)
        count + length(locals) <= 1_000_000 || throw(MalformedError("too many locals"))
        t = read_valtype(bio)
        append!(locals, (t for _ in 1:count))
    end
    f.locals = locals
    f.body = read_expr(bio)
    eof(bio) || throw(MalformedError("trailing bytes in function body"))
end

function read_name_custom!(io::IO, m::WasmModule)
    nimports = numfuncimports(m)
    # Parse fully before mutating `m`, so a malformed name section leaves the
    # module untouched (the caller then preserves it as an opaque custom section).
    importnames = Dict{UInt32,String}()
    funcnames = Dict{Int,String}()
    while !eof(io)
        subid = read(io, UInt8)
        sublen = read_uleb(io, 32)
        payload = read(io, sublen)
        length(payload) == sublen || throw(MalformedError("truncated name subsection"))
        if subid == 1
            sio = IOBuffer(payload)
            n = read_uleb(sio, 32)
            for _ in 1:n
                idx = Int(read_u32(sio))
                name = read_name_str(sio)
                if idx < nimports
                    importnames[UInt32(idx)] = name
                elseif idx - nimports < length(m.funcs)
                    funcnames[idx-nimports] = name
                end
            end
        end
        # other name subsections (module/local/type names) are dropped for now
    end
    merge!(m.funcnames, importnames)
    for (i, name) in funcnames
        m.funcs[i+1].name = name
    end
end

"""
    decode(bytes) -> WasmModule

Parse a wasm binary. Inverse of [`encode`](@ref) (function names from the
`name` custom section are restored; other name subsections are dropped).
"""
function decode(bytes::AbstractVector{UInt8})
    io = IOBuffer(bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes))
    try
        return _decode(io)
    catch e
        # The spec classifies truncation as malformedness ("unexpected end").
        e isa EOFError && throw(MalformedError("unexpected end of input"))
        rethrow()
    end
end

function _decode(io::IO)
    magic = read(io, 4)
    magic == UInt8[0x00, 0x61, 0x73, 0x6D] || throw(MalformedError("bad magic"))
    version = read(io, 4)
    version == UInt8[0x01, 0x00, 0x00, 0x00] || throw(MalformedError("unsupported version"))
    m = WasmModule()
    lastid = -1
    sawcode = false
    datacount = nothing
    while !eof(io)
        id = read(io, UInt8)
        size = read_uleb(io, 32)
        payload = read(io, size)
        length(payload) == size || throw(MalformedError("truncated section $id"))
        s = IOBuffer(payload)
        if id != 0
            # sections must appear in order; datacount (12) sits between 9 and 10
            order = id == 12 ? 95 : id == 10 ? 100 : id == 11 ? 110 : id == 13 ? 55 : Int(id) * 10
            order > lastid || throw(MalformedError("section $id out of order"))
            lastid = order
        end
        if id == 0
            name = read_name_str(s)
            rest = read(s)
            if name == "name"
                try
                    read_name_custom!(IOBuffer(rest), m)
                catch
                    # Per spec, errors in custom-section data must not
                    # invalidate the module; keep the section opaquely.
                    push!(m.customs, CustomSection(name, rest))
                end
            else
                push!(m.customs, CustomSection(name, rest))
            end
        elseif id == 1
            m.types = read_vec(read_rectype, s)
        elseif id == 2
            m.imports = read_vec(s) do io
                Import(read_name_str(io), read_name_str(io), read_importdesc(io))
            end
        elseif id == 3
            typeidxs = read_vec(read_u32, s)
            m.funcs = [Func(t, ValType[], Inst[], nothing) for t in typeidxs]
        elseif id == 4
            m.tables = read_vec(s) do io
                if peek(io, UInt8) == 0x40
                    read(io, UInt8)
                    read(io, UInt8) == 0x00 || throw(MalformedError("invalid table encoding"))
                    tt = read_tabletype(io)
                    Table(tt, read_expr(io))
                else
                    Table(read_tabletype(io), nothing)
                end
            end
        elseif id == 5
            m.mems = read_vec(io -> MemoryType(read_limits(io)), s)
        elseif id == 6
            m.globals = read_vec(s) do io
                gt = read_globaltype(io)
                Global(gt, read_expr(io))
            end
        elseif id == 7
            m.exports = read_vec(s) do io
                name = read_name_str(io)
                kind = read(io, UInt8)
                haskey(EXPORT_KINDS_REV, kind) || throw(MalformedError("invalid export kind"))
                Export(name, EXPORT_KINDS_REV[kind], read_u32(io))
            end
        elseif id == 8
            m.start = read_u32(s)
        elseif id == 9
            m.elems = read_vec(read_elem, s)
        elseif id == 10
            sawcode = true
            n = read_uleb(s, 32)
            n == length(m.funcs) || throw(MalformedError(
                "code section count $n does not match function section $(length(m.funcs))"))
            foreach(f -> read_code!(s, f), m.funcs)
        elseif id == 11
            m.datas = read_vec(read_data, s)
        elseif id == 12
            datacount = read_uleb(s, 32)
        elseif id == 13
            m.tags = read_vec(s) do io
                read(io, UInt8) == 0x00 || throw(MalformedError("invalid tag attribute"))
                TagType(read_u32(io))
            end
        else
            throw(MalformedError("unknown section id $id"))
        end
        id in (0, 10) || eof(s) || throw(MalformedError("trailing bytes in section $id"))
        id == 10 && !eof(s) && throw(MalformedError("trailing bytes in code section"))
    end
    isempty(m.funcs) || sawcode ||
        throw(MalformedError("function section without code section"))
    datacount === nothing || datacount == length(m.datas) || throw(MalformedError(
        "data count section ($datacount) disagrees with data section ($(length(m.datas)))"))
    return m
end
