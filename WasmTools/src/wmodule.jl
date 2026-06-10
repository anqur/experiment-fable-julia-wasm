# In-memory representation of a wasm module, mirroring the binary sections.

"""A function defined in this module. `locals` lists extra locals beyond the parameters."""
mutable struct Func
    typeidx::UInt32
    locals::Vector{ValType}
    body::Vector{Inst}
    name::Union{Nothing,String}
end
Func(typeidx::Integer, locals::Vector{ValType}, body::Vector{Inst}) =
    Func(UInt32(typeidx), locals, body, nothing)

"""Import descriptor for a function (a type index)."""
struct FuncDesc
    typeidx::UInt32
end

const ImportDesc = Union{FuncDesc, TableType, MemoryType, GlobalType, TagType}

struct Import
    mod::String
    name::String
    desc::ImportDesc
end

struct Export
    name::String
    kind::Symbol   # :func, :table, :memory, :global, :tag
    idx::UInt32
end
Export(name::AbstractString, kind::Symbol, idx::Integer) = Export(String(name), kind, UInt32(idx))

struct Global
    type::GlobalType
    init::Vector{Inst}
end

"""Table definition. `init` is an optional element init expression (GC extension)."""
struct Table
    type::TableType
    init::Union{Nothing,Vector{Inst}}
end
Table(type::TableType) = Table(type, nothing)

"""
Element segment. `mode` is `:active`, `:passive`, or `:declarative`.
`init` holds one constant expression per element (e.g. `[Inst(:ref_func, 3)]`).
For active segments, `tableidx`/`offset` give the target.

`exprform` and `explicit_tableidx` record which binary flavor the segment was
decoded from (expression-style flags 4-7, and the explicit-table-index flags
2/6 even when the index is 0) so re-encoding is byte-identical; hand-built
segments keep the defaults, which select the most compact encoding. These
hints do not participate in `==` (it compares segment semantics only).
"""
struct Elem
    mode::Symbol
    tableidx::UInt32
    offset::Vector{Inst}
    reftype::RefType
    init::Vector{Vector{Inst}}
    exprform::Bool
    explicit_tableidx::Bool
end
Elem(mode::Symbol, tableidx::Integer, offset::Vector{Inst}, reftype::RefType,
     init::Vector{Vector{Inst}}) =
    Elem(mode, UInt32(tableidx), offset, reftype, init, false, false)
Elem(mode::Symbol, reftype::RefType, init::Vector{Vector{Inst}}) =
    Elem(mode, UInt32(0), Inst[], reftype, init)
Base.:(==)(a::Elem, b::Elem) = a.mode == b.mode && a.tableidx == b.tableidx &&
    a.offset == b.offset && a.reftype == b.reftype && a.init == b.init

"""Data segment. `mode` is `:active` or `:passive`."""
struct Data
    mode::Symbol
    memidx::UInt32
    offset::Vector{Inst}
    bytes::Vector{UInt8}
end
Data(bytes::Vector{UInt8}) = Data(:passive, UInt32(0), Inst[], bytes)
Base.:(==)(a::Data, b::Data) = a.mode == b.mode && a.memidx == b.memidx &&
    a.offset == b.offset && a.bytes == b.bytes

struct CustomSection
    name::String
    bytes::Vector{UInt8}
end

mutable struct WasmModule
    types::Vector{RecGroup}
    imports::Vector{Import}
    funcs::Vector{Func}
    tables::Vector{Table}
    mems::Vector{MemoryType}
    globals::Vector{Global}
    exports::Vector{Export}
    start::Union{Nothing,UInt32}
    elems::Vector{Elem}
    datas::Vector{Data}
    tags::Vector{TagType}
    customs::Vector{CustomSection}
    funcnames::Dict{UInt32,String}   # names of *imported* functions, keyed by
                                     # function index (defined functions carry
                                     # their name on `Func.name`)
end
WasmModule() = WasmModule(RecGroup[], Import[], Func[], Table[], MemoryType[],
                          Global[], Export[], nothing, Elem[], Data[],
                          TagType[], CustomSection[], Dict{UInt32,String}())

"""All type-section entries flattened across rec groups, in index order."""
flattypes(m::WasmModule) = SubType[st for rg in m.types for st in rg.types]

numtypes(m::WasmModule) = sum(rg -> length(rg.types), m.types; init=0)

"""Look up the type-section entry for flat index `i` (0-based)."""
function gettype(m::WasmModule, i::Integer)
    n = 0
    for rg in m.types
        if i < n + length(rg.types)
            return rg.types[i - n + 1]
        end
        n += length(rg.types)
    end
    throw(BoundsError(m.types, i))
end

"""The `FuncType` of flat type index `i`, which must name a function type."""
function getfunctype(m::WasmModule, i::Integer)
    st = gettype(m, i)
    st.comp isa FuncType || throw(ArgumentError("type index $i is not a function type"))
    return st.comp::FuncType
end

"""
    addtype!(m, t) -> typeidx

Append a type (CompositeType / SubType / RecGroup) to the type section,
returning the flat index of its (first) entry. For plain `CompositeType`s,
an existing structurally-equal singleton entry is reused.
"""
function addtype!(m::WasmModule, ct::CompositeType)
    i = 0
    for rg in m.types
        if length(rg.types) == 1
            st = rg.types[1]
            if st.final && isempty(st.supers) && st.comp == ct
                return UInt32(i)
            end
        end
        i += length(rg.types)
    end
    push!(m.types, RecGroup(ct))
    return UInt32(numtypes(m) - 1)
end
function addtype!(m::WasmModule, st::SubType)
    push!(m.types, RecGroup(st))
    return UInt32(numtypes(m) - 1)
end
function addtype!(m::WasmModule, rg::RecGroup)
    idx = numtypes(m)
    push!(m.types, rg)
    return UInt32(idx)
end

numimports(m::WasmModule, kind::Type{<:ImportDesc}) = count(im -> im.desc isa kind, m.imports)
numfuncimports(m::WasmModule) = numimports(m, FuncDesc)

"""
    addfunc!(m, name, ft::FuncType, locals, body; export_name=nothing) -> funcidx

Define a function, interning its type. Returns the function index (accounting
for imported functions). Pass `export_name` to also export it.
"""
function addfunc!(m::WasmModule, name::Union{Nothing,String}, ft::FuncType,
                  locals::Vector{ValType}, body::Vector{Inst};
                  export_name::Union{Nothing,String}=nothing)
    typeidx = addtype!(m, ft)
    push!(m.funcs, Func(typeidx, locals, body, name))
    idx = UInt32(numfuncimports(m) + length(m.funcs) - 1)
    export_name !== nothing && push!(m.exports, Export(export_name, :func, idx))
    return idx
end

"""
    importfunc!(m, mod, name, ft::FuncType) -> funcidx

Add a function import. Must be called before any `addfunc!` since imported
functions precede defined ones in the index space.
"""
function importfunc!(m::WasmModule, mod::String, name::String, ft::FuncType)
    isempty(m.funcs) || throw(ArgumentError(
        "function imports must be added before defined functions (index space order)"))
    typeidx = addtype!(m, ft)
    push!(m.imports, Import(mod, name, FuncDesc(typeidx)))
    return UInt32(numfuncimports(m) - 1)
end

"""Index-space size helpers (imports + definitions)."""
numfuncs(m::WasmModule) = numfuncimports(m) + length(m.funcs)
numglobals(m::WasmModule) = numimports(m, GlobalType) + length(m.globals)
numtables(m::WasmModule) = numimports(m, TableType) + length(m.tables)
nummems(m::WasmModule) = numimports(m, MemoryType) + length(m.mems)
