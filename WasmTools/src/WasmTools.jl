"""
    WasmTools

Pure-Julia library for reading, writing, and manipulating WebAssembly modules,
including WasmGC (struct/array/reference types), function references, tail
calls, and exception handling.

The in-memory representation ([`WasmModule`](@ref)) mirrors the binary format:
flat instruction sequences with explicit `block`/`end` structure, type-section
rec groups, and index-based references. [`encode`](@ref)/[`decode`](@ref)
convert to/from binary.
"""
module WasmTools

include("types.jl")
include("leb.jl")
include("instructions.jl")
include("wmodule.jl")
include("encode.jl")
include("decode.jl")
include("wat.jl")

export
    # value/heap types
    NumType, PackedType, HeapType, RefType, ValType, StorageType,
    I32, I64, F32, F64, V128, I8, I16,
    FuncHT, ExternHT, AnyHT, EqHT, I31HT, StructHT, ArrayHT, ExnHT,
    NoneHT, NoFuncHT, NoExternHT, NoExnHT,
    FuncRefT, ExternRefT, AnyRefT, EqRefT, I31RefT, StructRefT, ArrayRefT,
    NullRefT, NullFuncRefT, ExnRefT,
    typeref, isconcrete,
    # composite types
    FieldType, FuncType, StructType, ArrayType, CompositeType,
    SubType, RecGroup,
    Limits, MemoryType, TableType, GlobalType, TagType,
    # instructions
    Inst, MemArg, Catch, Instructions, opspec,
    # module structure
    WasmModule, Func, Import, FuncDesc, Export, Global, Table, Elem, Data,
    CustomSection,
    flattypes, numtypes, gettype, getfunctype, addtype!, addfunc!, importfunc!,
    numfuncs, numfuncimports, numglobals, numtables, nummems,
    # binary format
    encode, decode, MalformedError,
    # text format
    print_wat, wat

end # module WasmTools
