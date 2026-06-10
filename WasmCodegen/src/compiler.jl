# The IRCode -> wasm compiler.
#
# CFG lowering uses a dispatcher loop: a `next`-block local, the basic blocks
# as a ladder of nested wasm blocks, and a br_table at the loop head. This is
# correct for arbitrary (even irreducible) control flow; structured relooping
# is a planned optimization.
#
# SSA values live in wasm locals; phi nodes are resolved with parallel-copy
# semantics on the edges (push all incoming values, then set in reverse).

"""Placeholder call target patched to a final function index after the worklist drains."""
struct CallTarget
    mi::Core.MethodInstance
end

"""Call to an auto-generated host import for a builtin on host-resident values."""
struct HostCall
    key::Any    # e.g. (:sizeof, String)
end

"""Placeholder `global.get` immediate for a materialized host-constant object,
patched to the final global index at assembly."""
struct ValueGlobal
    key::Int    # registration index into mc.valueglobals
end

struct Offload
    key::Any                   # MethodInstance, or a builtin HostCall key
    func::Any                  # the callable (singleton instance)
    argtypes::Vector{Any}      # Julia argument types (ghosts reconstructed in thunk)
    rettype::Any
    params::Vector{Symbol}
    results::Vector{Symbol}
    name::String
    mod::String                # import module ("julia", or e.g. "wasm:js-string")
end
Offload(key, func, argtypes, rettype, params, results, name) =
    Offload(key, func, argtypes, rettype, params, results, name, "julia")

"""How a Julia struct/tuple type lowers to a WasmGC struct."""
struct GCStructInfo
    typeidx::Int
    fieldmap::Vector{Int}      # julia field idx -> wasm field idx (-1 = ghost)
    fieldtypes::Vector{Any}    # julia field types
end

mutable struct ModuleCompiler
    wmod::WasmModule
    order::Vector{Core.MethodInstance}            # discovery order of compiled funcs
    status::Dict{Core.MethodInstance,Symbol}      # :pending / :compiled / :offload
    bodies::Dict{Core.MethodInstance,Func}
    sigs::Dict{Core.MethodInstance,FuncType}
    offloads::Vector{Offload}
    offload_ids::Dict{Any,Int}
    queue::Vector{Core.MethodInstance}
    failures::Dict{Core.MethodInstance,CompileError}
    gctypes::Vector{SubType}                      # GC type entries, one rec group
    gcinfo::IdDict{Any,GCStructInfo}
    gcarrays::IdDict{Any,Int}                     # Memory{T} -> array typeidx
    gcmemrefs::IdDict{Any,Int}                    # MemoryRef{T} -> struct typeidx
    gcboxes::IdDict{Any,Int}                      # scalar T -> box struct typeidx
                                                  #   (for Union{Nothing,T})
    eh_used::Bool                                 # some function has try/catch
    interp::WasmInterp                            # inference w/ the overlay table
    hostconsts::Vector{Any}                       # Symbol/String literals, as
                                                  # imported externref globals
    hostconst_ids::IdDict{Any,Int}
    valueglobals::Vector{Any}                     # mutable constant objects
                                                  # (Dicts, Vectors, Memorys),
                                                  # materialized as wasm globals
    valueglobal_ids::IdDict{Any,Int}
end
ModuleCompiler() = ModuleCompiler(WasmModule(), Core.MethodInstance[],
                                  Dict(), Dict(), Dict(), Offload[], Dict(),
                                  Core.MethodInstance[], Dict(),
                                  SubType[], IdDict{Any,GCStructInfo}(),
                                  IdDict{Any,Int}(), IdDict{Any,Int}(),
                                  IdDict{Any,Int}(), false, WasmInterp(),
                                  Any[], IdDict{Any,Int}(),
                                  Any[], IdDict{Any,Int}())

# Types with special runtime layouts that must not lower as plain GC structs.
const _SPECIAL_LAYOUT = Any[String, Symbol, Module, DataType, Core.MethodInstance,
                            Core.CodeInstance, Task, Core.SimpleVector]

"""Is `T` a Julia type we lower to a WasmGC struct? (`Array` qualifies — it is
an ordinary mutable struct over `Memory`; `Memory`/`MemoryRef` lower specially.)"""
function is_gc_struct(@nospecialize T)
    T isa DataType || return false
    isconcretetype(T) || return false
    any(S -> T <: S, _SPECIAL_LAYOUT) && return false
    (T <: GenericMemory || T <: Core.GenericMemoryRef || T <: Ptr) && return false
    isghost(T) && return false
    scalar_repr(T) === nothing || return false
    return isstructtype(T) || T <: Tuple
end

"""Lower `Memory{T}` to a (mutable-element) WasmGC array type; returns the type index."""
function gc_array!(mc::ModuleCompiler, @nospecialize MT)
    idx = get(mc.gcarrays, MT, nothing)
    idx === nothing || return idx
    MT isa DataType && MT <: GenericMemory && isconcretetype(MT) ||
        throw(CompileError("unsupported memory type $MT"))
    MT.parameters[1] === :not_atomic ||
        throw(CompileError("atomic memory unsupported: $MT"))
    elT = MT.parameters[2]
    isghost(elT) && throw(CompileError("ghost-element memory unsupported: $MT"))
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(ArrayType(FieldType(I32, true))))   # placeholder
    mc.gcarrays[MT] = idx
    mc.gctypes[idx+1] = SubType(ArrayType(FieldType(field_storage(mc, elT), true)))
    return idx
end

"""Lower `MemoryRef{T}` to a `{mem::(ref null \$arr), idx::i32}` GC struct."""
function gc_memref!(mc::ModuleCompiler, @nospecialize RT)
    idx = get(mc.gcmemrefs, RT, nothing)
    idx === nothing || return idx
    RT isa DataType && RT <: Core.GenericMemoryRef && isconcretetype(RT) ||
        throw(CompileError("unsupported memoryref type $RT"))
    MT = fieldtype(RT, :mem)
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(StructType(FieldType[])))           # placeholder
    mc.gcmemrefs[RT] = idx
    arr = gc_array!(mc, MT)
    mc.gctypes[idx+1] = SubType(StructType(
        [FieldType(RefType(true, HeapType(arr)), false), FieldType(I32, false)]))
    return idx
end

"""The shared `{lo::i64, hi::i64}` struct type for Int128/UInt128 values."""
function gc_i128!(mc::ModuleCompiler)
    idx = get(mc.gcboxes, Int128, nothing)
    idx === nothing || return idx
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(StructType([FieldType(I64, false),
                                          FieldType(I64, false)])))
    mc.gcboxes[Int128] = idx
    return idx
end

"""
The `{bytes::(ref null (array mut i8))}` struct type representing `String`.
Strings are wasm-GC-resident — array+length instead of host JS strings (the
WIT model, with a GC array standing in for linear memory). The byte array
type is shared with `Memory{UInt8}`, so bytes move between strings and
vectors with `array.copy`. Crossing the boundary they are externalized
(`extern.convert_any`) and the host reads/writes them through the exported
`__str_len`/`__str_get`/`__str_new`/`__str_set` accessors.
"""
function gc_string!(mc::ModuleCompiler)
    idx = get(mc.gcboxes, String, nothing)
    idx === nothing || return idx
    arr = gc_array!(mc, Memory{UInt8})
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(StructType(
        [FieldType(RefType(true, HeapType(arr)), false)])))
    mc.gcboxes[String] = idx
    return idx
end

"""Box type for scalar `T` inside `Union{Nothing,T}`: a one-field immutable
struct at full storage width (no packing — boxes are transient)."""
function gc_box!(mc::ModuleCompiler, @nospecialize T)
    idx = get(mc.gcboxes, T, nothing)
    idx === nothing || return idx
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(StructType([FieldType(scalar_repr(T).vt, false)])))
    mc.gcboxes[T] = idx
    return idx
end

"""`(boxtypeidx, T)` when `U` is `Union{Nothing,T}` with scalar `T`, else `nothing`."""
function union_box_info(mc::ModuleCompiler, @nospecialize U)
    U isa Union || return nothing
    Us = Base.uniontypes(U)
    (length(Us) == 2 && Nothing in Us) || return nothing
    other = Us[1] === Nothing ? Us[2] : Us[1]
    scalar_repr(other) === nothing && return nothing
    return (gc_box!(mc, other), other)
end

"""
Storage type for a struct field of Julia type `T` (packed sub-words).
Field types with no wasm lowering (e.g. `VersionNumber.prerelease`'s vararg
tuple) are *erased* to `anyref`: writes coerce (boxing scalars, converting
externrefs), reads of such fields remain unsupported and fail loudly at the
use site — which is exactly right for fields the compiled code never touches.
"""
function field_storage(mc::ModuleCompiler, @nospecialize T)
    T === Bool && return I8
    r = scalar_repr(T)
    if r !== nothing
        T === Char && return I32
        r.isfloat && return r.vt
        r.bits == 8 && return I8
        r.bits == 16 && return I16
        return r.vt
    end
    vt = try
        valtype_for(mc, T)
    catch err
        err isa CompileError || rethrow()
        return RefType(true, AnyHT)   # erased field
    end
    vt === nothing && throw(CompileError("ghost field type $T should be skipped"))
    return vt
end

"""Push `ref` coerced to `anyref` (for writes into erased fields)."""
function emit_value_anyref!(fc, @nospecialize ref)
    Tsrc = widen(argtype(fc, ref))
    if isghost(Tsrc)
        emit!(fc, ref_null(AnyHT))
        return
    end
    vt = valtype_for(fc.mc, Tsrc)
    if vt isa NumType
        emit_value!(fc, ref)
        emit!(fc, struct_new(gc_box!(fc.mc, Tsrc)))
    elseif vt == ExternRefT
        emit_value!(fc, ref)
        emit!(fc, Inst(:any_convert_extern))
    elseif vt isa RefType
        emit_value!(fc, ref)   # every wasm-GC ref we produce is <: anyref
    else
        throw(CompileError("cannot store a $Tsrc into an anyref-erased field"))
    end
end

"""Is this field stored erased (its Julia type has no direct lowering)?"""
function _erased_field(mc::ModuleCompiler, @nospecialize FT)
    st = field_storage(mc, FT)
    st == RefType(true, AnyHT) || return false
    vt = try
        valtype_for(mc, FT)
    catch
        return true
    end
    return vt != RefType(true, AnyHT)
end

"""Register (or look up) the WasmGC struct lowering of `T`."""
function gc_struct!(mc::ModuleCompiler, @nospecialize T)
    info = get(mc.gcinfo, T, nothing)
    info === nothing || return info
    is_gc_struct(T) || throw(CompileError("type $T does not lower to a GC struct"))
    # Reserve the index first so self-referential types terminate.
    idx = length(mc.gctypes)
    push!(mc.gctypes, SubType(StructType(FieldType[])))
    n = fieldcount(T)
    fieldmap = fill(-1, n)
    ftypes = Any[fieldtype(T, i) for i in 1:n]
    info = GCStructInfo(idx, fieldmap, ftypes)
    mc.gcinfo[T] = info
    fields = FieldType[]
    mut = ismutabletype(T)
    for i in 1:n
        FT = ftypes[i]
        isghost(FT) && continue
        st = try
            field_storage(mc, FT)
        catch err
            err isa CompileError || rethrow()
            throw(CompileError("field $(fieldname(T, i))::$FT of $T: $(err.msg)"))
        end
        # `const` fields of mutable structs are wasm-immutable too, so the
        # validator rejects any struct.set we might erroneously emit for them
        # (defense in depth; emit_setfield! already traps on const fields).
        push!(fields, FieldType(st, mut && !Base.isconst(T, i)))
        fieldmap[i] = length(fields) - 1
    end
    mc.gctypes[idx+1] = SubType(StructType(fields))
    return info
end

"""
Wasm value type for `T`, or `nothing` for ghosts. Extends `wasm_valtype` with
GC struct refs and `Union{Nothing,T}` as nullable refs.
"""
function valtype_for(mc::ModuleCompiler, @nospecialize T)
    isghost(T) && return nothing
    r = scalar_repr(T)
    r !== nothing && return r.vt
    # explicitly registered host/engine-resident types (e.g. JSRuntime's
    # JSString) stay externref even when they would lower structurally
    T isa Type && haskey(EXTERNREF_TYPES, T) && return ExternRefT
    if T isa Union
        U = Base.uniontypes(T)
        if length(U) == 2 && Nothing in U
            other = U[1] === Nothing ? U[2] : U[1]
            vt = try
                valtype_for(mc, other)
            catch err
                err isa CompileError || rethrow()
                nothing
            end
            # already a reference: reuse its heap type, nullable
            vt isa RefType && return RefType(true, vt.ht)
            # scalar: box into a single-field struct; nothing is null
            vt isa NumType && return RefType(true, HeapType(gc_box!(mc, other)))
        end
        # general small unions of concrete scalars/structs: anyref, with
        # scalars boxed per-type; Nothing (if present) is null. ref.test/
        # ref.cast against the box/struct types recover the variants.
        ok = true
        for u in U
            u === Nothing && continue
            if scalar_repr(u) !== nothing
                gc_box!(mc, u)
            elseif u === String
                gc_string!(mc)
            elseif is_gc_struct(u)
                gc_struct!(mc, u)
            else
                ok = false
                break
            end
        end
        ok && return RefType(true, AnyHT)
        throw(CompileError("unsupported union type $T"))
    end
    T === String && return RefType(true, HeapType(gc_string!(mc)))
    if T === Int128 || T === UInt128
        # 128-bit integers: a {lo::i64, hi::i64} struct; signedness lives in
        # the operations (see emit_i128! in intrinsics.jl)
        return RefType(true, HeapType(gc_i128!(mc)))
    end
    if T isa DataType && T <: GenericMemory
        return RefType(true, HeapType(gc_array!(mc, T)))
    elseif T isa DataType && T <: Core.GenericMemoryRef
        return RefType(true, HeapType(gc_memref!(mc, T)))
    end
    is_gc_struct(T) && return RefType(true, HeapType(gc_struct!(mc, T).typeidx))
    # Fallback: concrete types we cannot lower (String, Symbol, BigInt, ...)
    # live host-side and flow through wasm as opaque externrefs, crossing the
    # boundary only at offloaded calls.
    if T isa DataType && isconcretetype(T) && !(T <: Ptr)
        return ExternRefT
    end
    throw(CompileError("unsupported Julia type $T"))
end

"""
Register a host import implementing a builtin over host-resident values
(e.g. `sizeof(::String)`). Returns the `HostCall` immediate to emit.
Pass `mod`/`name` for fixed engine-provided imports (e.g. the js-string
builtins, module "wasm:js-string"); the default is a generated name in the
"julia" namespace bound by the embedder.
"""
function request_hostcall!(mc::ModuleCompiler, key, func, argtypes::Vector{Any},
                           @nospecialize(rettype); mod::String="julia",
                           name::Union{Nothing,String}=nothing)
    if !haskey(mc.offload_ids, key)
        params = Symbol[offload_kind(mc, T) for T in argtypes if !isghost(T)]
        results = Symbol[]
        isghost(rettype) || rettype === Union{} || push!(results, offload_kind(mc, rettype))
        tag = key isa Core.MethodInstance ? key.def.name : key isa Tuple ? key[1] : key
        nm = name === nothing ? "host_$(length(mc.offloads))_$(tag)" : name
        push!(mc.offloads,
              Offload(key, func, argtypes, rettype, params, results, nm, mod))
        mc.offload_ids[key] = length(mc.offloads) - 1
    end
    return HostCall(key)
end

"""Boundary kind for offloaded signatures: scalar kinds or `:externref`."""
function offload_kind(mc::ModuleCompiler, @nospecialize T)
    k = valkind_sym(T)
    k === nothing || return k
    # Strings cross externalized (extern.convert_any); a generated wrapper
    # function does the conversion so call sites stay GC-typed (see
    # _make_offload_wrapper!), and the host reads bytes via __str_* exports.
    T === String && return :externref
    vt = valtype_for(mc, T)   # throws CompileError if not representable
    vt == ExternRefT && return :externref
    throw(CompileError("cannot pass $T across the offload boundary (wasm-GC-resident)"))
end

"""The non-Nothing component of `Union{Nothing,T}`, or `T` itself."""
function strip_nothing(@nospecialize T)
    if T isa Union
        U = Base.uniontypes(T)
        length(U) == 2 && Nothing in U && return U[1] === Nothing ? U[2] : U[1]
    end
    return T
end

widen(@nospecialize t) = CC.widenconst(t)

"""IR for a method instance at full optimization under the wasm interpreter."""
function method_ir(mc::ModuleCompiler, mi::Core.MethodInstance)
    matches = Base.code_ircode_by_type(mi.specTypes;
                                       world=mc.interp.world, interp=mc.interp)
    length(matches) == 1 ||
        throw(CompileError("expected unique method match for $(mi.specTypes)"))
    return matches[1]   # (IRCode, rettype)
end

function mi_signature(mc::ModuleCompiler, mi::Core.MethodInstance, @nospecialize(rettype))
    sig = Base.unwrap_unionall(mi.specTypes)
    argts = collect(Any, sig.parameters)
    params = ValType[]
    # the callable itself is a parameter when it carries data (closures);
    # singleton functions are ghosts and contribute nothing
    for T in argts
        vt = valtype_for(mc, T)
        vt === nothing && continue
        push!(params, vt)
    end
    results = ValType[]
    if rettype !== Union{}
        vt = valtype_for(mc, rettype)
        vt === nothing || push!(results, vt)
    end
    return FuncType(params, results)
end

"""Request compilation of `mi`, enqueueing it if new. Returns its `CallTarget`."""
function request!(mc::ModuleCompiler, mi::Core.MethodInstance)
    if !haskey(mc.status, mi)
        mc.status[mi] = :pending
        push!(mc.order, mi)
        push!(mc.queue, mi)
    end
    return CallTarget(mi)
end

"""Demote `mi` to a host-offloaded import (scalar signatures only)."""
function offload!(mc::ModuleCompiler, mi::Core.MethodInstance, why::Exception)
    sig = Base.unwrap_unionall(mi.specTypes)
    argts = collect(Any, sig.parameters)
    ftype = argts[1]
    isghost(ftype) ||
        throw(CompileError("cannot offload non-singleton callee $ftype ($(sprint(showerror, why)))"))
    _, rettype = method_ir(mc, mi)
    rettype = widen(rettype)
    args = Any[T for T in argts[2:end]]   # full list; ghosts reconstructed in the thunk
    params, results = try
        res = if isghost(rettype) || rettype === Union{}
            Symbol[]
        elseif (bi = union_box_info(mc, rettype)) !== nothing
            # nullable-scalar return crosses the wire as (value, flag); a wasm
            # wrapper boxes it back into the nullable ref (see compile_wasm)
            Symbol[valkind_sym(bi[2]), :i32]
        else
            Symbol[offload_kind(mc, rettype)]
        end
        (Symbol[offload_kind(mc, T) for T in args if !isghost(T)], res)
    catch err
        err isa CompileError || rethrow()
        throw(CompileError("cannot offload $(mi): $(err.msg); " *
                           "original failure: $(sprint(showerror, why))"))
    end
    name = "offload_$(length(mc.offloads))_$(mi.def.name)"
    push!(mc.offloads, Offload(mi, ghost_instance(ftype), args, rettype, params, results, name))
    mc.offload_ids[mi] = length(mc.offloads) - 1
    mc.status[mi] = :offload
    return nothing
end

# --- per-function compiler ----------------------------------------------------

mutable struct FuncCompiler
    mc::ModuleCompiler
    ir::Any                      # Compiler.IRCode
    rettype::Any
    nparams::Int
    argmap::Vector{Int}          # julia argument n -> wasm local idx (-1 = ghost)
    ssalocal::Vector{Int}        # ssa idx -> wasm local idx (-1 = none)
    locals::Vector{ValType}      # extra locals beyond params
    body::Vector{Inst}
    depth::Int                   # open blocks between emission point and dispatch loop
    nextlocal::Int
    scratch::Dict{ValType,Vector{Int}}
    scratch_used::Dict{ValType,Int}
    ssapair::Dict{Int,Tuple{Int,Int}}   # ssa idx -> (value, flag) locals for
                                        # checked-arithmetic tuple results
    handlers::Vector{Tuple{Int,Int}}    # per block: innermost (catch_dest, enter_block),
                                        # (0, 0) when unprotected
    upsilons::Dict{Int,Tuple{Int,Int}}  # upsilon stmt idx -> (PhiC local, PhiC stmt idx)
    protected::Bool                     # currently emitting inside a try region
    nuses::Vector{Int}                  # ssa idx -> use count (dead pure type-level
                                        # statements transitively zeroed)
end

emit!(fc::FuncCompiler, insts::Inst...) = append!(fc.body, insts)

function newlocal!(fc::FuncCompiler, vt::ValType)
    push!(fc.locals, vt)
    return fc.nparams + length(fc.locals) - 1
end

function scratch_local!(fc::FuncCompiler, vt::ValType)
    pool = get!(Vector{Int}, fc.scratch, vt)
    used = get(fc.scratch_used, vt, 0) + 1
    fc.scratch_used[vt] = used
    used <= length(pool) && return pool[used]
    idx = newlocal!(fc, vt)
    push!(pool, idx)
    return idx
end
reset_scratch!(fc::FuncCompiler) = empty!(fc.scratch_used)

stmt_at(fc::FuncCompiler, i::Int) = fc.ir.stmts[i][:stmt]
type_at(fc::FuncCompiler, i::Int) = widen(fc.ir.stmts[i][:type])

"""Widened Julia type of an IR value reference."""
function argtype(fc::FuncCompiler, @nospecialize ref)
    ref isa Core.SSAValue && return type_at(fc, ref.id)
    ref isa Core.Argument && return widen(fc.ir.argtypes[ref.n])
    ref isa GlobalRef && return typeof(getglobal(ref.mod, ref.name))
    ref isa QuoteNode && return typeof(ref.value)
    return typeof(ref)
end

"""
Instruction sink for building constant expressions (wasm global initializers).
Shares the emission helpers with FuncCompiler via `emit!` and `.mc`. Inside a
sink, nested mutable objects are materialized inline (the parent owns them);
at function level they become shared value-globals instead.
"""
struct ConstSink
    mc::ModuleCompiler
    body::Vector{Inst}
end
emit!(s::ConstSink, insts::Inst...) = append!(s.body, insts)

"""Raw little-endian bytes of a numeric-element host Memory, matching the wasm
array element storage (i8/i16 packed, i32/i64/f32/f64, Char as raw bits)."""
function _const_bytes(st, @nospecialize(elT), v)
    io = IOBuffer()
    for x in v
        if st isa PackedType
            if st == I8
                write(io, x isa Bool ? UInt8(x) : reinterpret(UInt8, x))
            else
                write(io, htol(reinterpret(UInt16, x)))
            end
        elseif st == I32
            bits = x isa Char ? reinterpret(UInt32, x) :
                   elT === Float32 ? reinterpret(UInt32, x) : reinterpret(UInt32, x)
            write(io, htol(bits))
        elseif st == F32
            write(io, htol(reinterpret(UInt32, x)))
        elseif st == F64
            write(io, htol(reinterpret(UInt64, x)))
        else
            write(io, htol(reinterpret(UInt64, x)))
        end
    end
    return take!(io)
end

"""Intern a mutable host constant; returns its `ValueGlobal` placeholder."""
function register_valueglobal!(mc::ModuleCompiler, @nospecialize v)
    idx = get(mc.valueglobal_ids, v, nothing)
    if idx === nothing
        push!(mc.valueglobals, v)
        idx = length(mc.valueglobals) - 1
        mc.valueglobal_ids[v] = idx
    end
    return ValueGlobal(idx)
end

"""Emit a constant for a Julia value."""
function emit_const!(fc, @nospecialize v)
    T = typeof(v)
    if isghost(T)
        return
    elseif v isa Bool
        emit!(fc, i32_const(Int32(v)))
    elseif v isa Char
        # Char is stored as its RAW bits (UTF-8 bytes left-justified), exactly
        # like native Julia — see reprs.jl. Storing the codepoint instead would
        # silently break bitcast/zext (e.g. UInt32(c) decodes raw bits).
        emit!(fc, i32_const(reinterpret(Int32, v)))
    elseif v isa Union{Int8,Int16,Int32}
        emit!(fc, i32_const(Int32(v)))
    elseif v isa Union{UInt8,UInt16}
        emit!(fc, i32_const(Int32(v)))
    elseif v isa UInt32
        emit!(fc, i32_const(reinterpret(Int32, v)))
    elseif v isa Int64
        emit!(fc, i64_const(v))
    elseif v isa UInt64
        emit!(fc, i64_const(reinterpret(Int64, v)))
    elseif v isa Float64
        emit!(fc, f64_const(v))
    elseif v isa Float32
        emit!(fc, f32_const(v))
    elseif v isa Union{Int128,UInt128}
        u = reinterpret(UInt128, v)
        emit!(fc, i64_const(reinterpret(Int64, UInt64(u & typemax(UInt64)))),
              i64_const(reinterpret(Int64, UInt64(u >> 64))),
              struct_new(gc_i128!(fc.mc)))
    elseif isprimitivetype(T) && !(T <: Ptr) && sizeof(T) <= 8
        # unknown primitive type (Kind, enum storage, ...): emit its bits
        sz = sizeof(T)
        if sz == 1
            emit!(fc, i32_const(Int32(reinterpret(UInt8, v))))
        elseif sz == 2
            emit!(fc, i32_const(Int32(reinterpret(UInt16, v))))
        elseif sz == 4
            emit!(fc, i32_const(reinterpret(Int32, v)))
        else
            emit!(fc, i64_const(reinterpret(Int64, v)))
        end
    elseif T isa DataType && T <: GenericMemory && isconcretetype(T)
        if fc isa ConstSink
            arr = gc_array!(fc.mc, T)
            elT = T.parameters[2]
            st = field_storage(fc.mc, elT)
            n = length(v)
            if !(st isa RefType) && n > 64
                # large numeric table: passive data segment + array.new_data
                # (engines cap array.new_fixed operand counts, e.g. V8 at 10k)
                bytes = _const_bytes(st, elT, v)
                push!(fc.mc.wmod.datas, Data(bytes))
                dataidx = length(fc.mc.wmod.datas) - 1
                emit!(fc, i32_const(0), i32_const(n), array_new_data(arr, dataidx))
            else
                n > 9000 &&
                    throw(CompileError("constant ref-array too large to materialize: $n"))
                for i in 1:n
                    if isassigned(v, i)
                        emit_const_field!(fc, v[i], elT)
                    elseif st isa RefType
                        emit!(fc, ref_null(st.ht))   # undef slot (e.g. Dict keys)
                    else
                        throw(CompileError("unassigned non-ref constant slot in $T"))
                    end
                end
                emit!(fc, array_new_fixed(arr, n))
            end
        else
            emit!(fc, Inst(:global_get, (register_valueglobal!(fc.mc, v),)))
        end
    elseif T isa DataType && T <: Core.GenericMemoryRef && isconcretetype(T)
        # fresh ref into a (nested) copy of its memory; offset preserved
        mref = gc_memref!(fc.mc, T)
        sink = fc isa ConstSink ? fc : fc   # memrefs are immutable; inline
        emit_const!(fc, getfield(v, :mem))
        emit!(fc, i32_const(Int32(Base.memoryrefoffset(v) - 1)), struct_new(mref))
    elseif is_gc_struct(T) && !ismutabletype(T)
        # immutable struct/tuple constant: materialize field by field
        info = gc_struct!(fc.mc, T)
        for k in 1:fieldcount(T)
            FT = info.fieldtypes[k]
            isghost(FT) && continue
            emit_const_field!(fc, getfield(v, k), FT)
        end
        emit!(fc, struct_new(info.typeidx))
    elseif is_gc_struct(T) && ismutabletype(T)
        if fc isa ConstSink
            # nested object owned by the enclosing constant: materialize inline
            info = gc_struct!(fc.mc, T)
            for k in 1:fieldcount(T)
                FT = info.fieldtypes[k]
                isghost(FT) && continue
                isdefined(v, k) ||
                    throw(CompileError("constant with undefined field: $T"))
                emit_const_field!(fc, getfield(v, k), FT)
            end
            emit!(fc, struct_new(info.typeidx))
        else
            # shared object: one wasm global per host object (identity preserved)
            emit!(fc, Inst(:global_get, (register_valueglobal!(fc.mc, v),)))
        end
    elseif v isa String
        # strings are wasm-resident byte arrays: a passive data segment holds
        # the contents; the value is shared via a value-global (one per
        # distinct literal object) materialized in the start function
        if fc isa ConstSink
            st = gc_string!(fc.mc)
            arr = gc_array!(fc.mc, Memory{UInt8})
            push!(fc.mc.wmod.datas, Data(Vector{UInt8}(codeunits(v))))
            dataidx = length(fc.mc.wmod.datas) - 1
            emit!(fc, i32_const(0), i32_const(Int32(ncodeunits(v))),
                  array_new_data(arr, dataidx), struct_new(st))
        else
            emit!(fc, Inst(:global_get, (register_valueglobal!(fc.mc, v),)))
        end
    elseif (vtc = try valtype_for(fc.mc, T) catch; nothing end) == ExternRefT
        # host-resident literal (Symbol, ...): read the imported externref
        # global bound to this exact value at instantiation
        emit!(fc, global_get(register_hostconst!(fc.mc, v)))
    else
        throw(CompileError("unsupported constant $v::$T"))
    end
end

"""Intern a host literal; returns its imported-global index."""
function register_hostconst!(mc::ModuleCompiler, @nospecialize v)
    idx = get(mc.hostconst_ids, v, nothing)
    idx === nothing || return idx
    push!(mc.hostconsts, v)
    idx = length(mc.hostconsts) - 1
    mc.hostconst_ids[v] = idx
    return idx
end

"""Emit a constant in a field context of declared type `FT` (boxes/nulls unions,
coerces values of anyref-erased fields)."""
function emit_const_field!(fc, @nospecialize(v), @nospecialize(FT))
    if _erased_field(fc.mc, FT)
        T = typeof(v)
        if isghost(T)
            emit!(fc, ref_null(AnyHT))
        elseif scalar_repr(T) !== nothing
            emit_const!(fc, v)
            emit!(fc, struct_new(gc_box!(fc.mc, T)))
        else
            # erased fields are never readable from wasm: constants that cannot
            # materialize (e.g. Strings) become null tombstones
            n0 = length(fc.body)
            try
                emit_const!(fc, v)
            catch err
                err isa CompileError || rethrow()
                resize!(fc.body, n0)
                emit!(fc, ref_null(AnyHT))
            end
        end
        return
    end
    vt = valtype_for(fc.mc, FT)
    vt === nothing && return
    if vt isa RefType
        if isghost(typeof(v))
            emit!(fc, ref_null(vt.ht))
            return
        end
        bi = union_box_info(fc.mc, FT)
        if bi !== nothing && scalar_repr(typeof(v)) !== nothing
            emit_const!(fc, v)
            emit!(fc, struct_new(bi[1]))
            return
        end
    end
    emit_const!(fc, v)
end

"""Push an IR value reference onto the wasm stack."""
function emit_value!(fc::FuncCompiler, @nospecialize ref)
    if ref isa Core.SSAValue
        isghost(type_at(fc, ref.id)) && return
        l = fc.ssalocal[ref.id]
        l >= 0 || throw(CompileError("use of value-less ssa %$(ref.id)"))
        emit!(fc, local_get(l))
    elseif ref isa Core.Argument
        T = widen(fc.ir.argtypes[ref.n])
        isghost(T) && return
        l = fc.argmap[ref.n]
        l >= 0 || throw(CompileError("use of unsupported argument _$(ref.n)"))
        emit!(fc, local_get(l))
    elseif ref isa GlobalRef
        isconst(ref.mod, ref.name) ||
            throw(CompileError("read of non-const global $(ref.mod).$(ref.name)"))
        emit_const!(fc, getglobal(ref.mod, ref.name))
    elseif ref isa QuoteNode
        emit_const!(fc, ref.value)
    else
        emit_const!(fc, ref)
    end
end

"""
Push `ref` in a context expecting Julia type `T`. Unlike `emit_value!`, ghost
values flowing into a nullable-ref context become `ref.null` (e.g. a literal
`nothing` feeding a `Union{Nothing,Node}` phi or argument).

`tolerant=true` is for phi-edge copies: a union incoming may be `nothing` (or
another union member) precisely on edges where the phi is dynamically dead —
guarded by a sibling phi — so the unbox must yield a dummy value instead of
trapping (the value is never consumed on those paths).
"""
function emit_value_typed!(fc::FuncCompiler, @nospecialize(ref), @nospecialize(T);
                           tolerant::Bool=false)
    vt = valtype_for(fc.mc, T)
    vt === nothing && return            # ghost context: no value at all
    if vt isa NumType
        # boxed union flowing into a refined scalar context: unbox (the value
        # is provably of type T here)
        Tsrc = widen(argtype(fc, ref))
        if Tsrc isa Union
            bi = union_box_info(fc.mc, Tsrc)
            if bi !== nothing
                if tolerant
                    r = scratch_local!(fc, valtype_for(fc.mc, Tsrc)::RefType)
                    emit_value!(fc, ref)
                    emit!(fc, local_tee(r), ref_is_null(), if_(vt), _const(vt, 0),
                          else_(), local_get(r), struct_get(bi[1], 0))
                    emit_norm!(fc, T)
                    emit!(fc, end_())
                else
                    emit_value!(fc, ref)
                    emit!(fc, struct_get(bi[1], 0))
                    emit_norm!(fc, T)
                end
                return
            end
            if valtype_for(fc.mc, Tsrc) isa RefType   # general anyref union
                box = gc_box!(fc.mc, T)
                if tolerant
                    r = scratch_local!(fc, valtype_for(fc.mc, Tsrc)::RefType)
                    emit_value!(fc, ref)
                    emit!(fc, local_tee(r), ref_test(HeapType(box)), if_(vt),
                          local_get(r), ref_cast(HeapType(box)), struct_get(box, 0))
                    emit_norm!(fc, T)
                    emit!(fc, else_(), _const(vt, 0), end_())
                else
                    emit_value!(fc, ref)
                    emit!(fc, ref_cast(HeapType(box)), struct_get(box, 0))
                    emit_norm!(fc, T)
                end
                return
            end
        end
    end
    if vt isa RefType
        Tsrc = widen(argtype(fc, ref))
        if isghost(Tsrc)
            emit!(fc, ref_null(vt.ht))
            return
        end
        # scalar flowing into Union{Nothing,scalar}: box it
        bi = union_box_info(fc.mc, T)
        if bi !== nothing && !(Tsrc isa Union) && scalar_repr(Tsrc) !== nothing
            emit_value!(fc, ref)
            emit!(fc, struct_new(bi[1]))
            return
        end
        # scalar flowing into a general anyref union: box at its own type
        if T isa Union && vt.ht == AnyHT && !(Tsrc isa Union) &&
           scalar_repr(Tsrc) !== nothing
            emit_value!(fc, ref)
            emit!(fc, struct_new(gc_box!(fc.mc, Tsrc)))
            return
        end
    end
    emit_value!(fc, ref)
end

"""Resolve the callee of a `:call` expression to a runtime value, or `nothing`."""
function resolve_callee(fc::FuncCompiler, @nospecialize ref)
    ref isa GlobalRef && isconst(ref.mod, ref.name) && return getglobal(ref.mod, ref.name)
    ref isa QuoteNode && return ref.value
    (ref isa Core.SSAValue || ref isa Core.Argument || ref isa Expr) && begin
        T = argtype(fc, ref)
        Base.issingletontype(T) && return T.instance
        return nothing
    end
    return ref
end

"""
Compute, per basic block, the innermost enclosing exception handler as a
`(catch_dest, enter_block)` pair (or `(0, 0)`), by propagating handler stacks
along CFG edges. `EnterNode` terminators push; `:leave` statements pop.
"""
function compute_handlers!(fc::FuncCompiler)
    ir = fc.ir
    nblocks = length(ir.cfg.blocks)
    fc.handlers = fill((0, 0), nblocks)
    stacks = Vector{Union{Nothing,Vector{Tuple{Int,Int}}}}(nothing, nblocks)
    stacks[1] = Tuple{Int,Int}[]
    work = [1]
    any_handler = false
    while !isempty(work)
        b = pop!(work)
        S = stacks[b]::Vector{Tuple{Int,Int}}
        fc.handlers[b] = isempty(S) ? (0, 0) : S[end]
        any_handler |= !isempty(S)
        out = copy(S)
        rng = ir.cfg.blocks[b].stmts
        term = stmt_at(fc, last(rng))
        for i in rng
            s = stmt_at(fc, i)
            if s isa Expr && s.head === :leave
                npop = count(a -> a !== nothing, s.args)
                for _ in 1:npop
                    isempty(out) && throw(CompileError("unbalanced :leave"))
                    pop!(out)
                end
                # statements after the leave run unprotected; with per-block
                # try_table granularity that is only sound if they cannot throw
                for j in (i+1):last(rng)
                    sj = stmt_at(fc, j)
                    sj isa Union{Nothing,Core.GotoNode,Core.GotoIfNot,
                                 Core.ReturnNode,Core.PhiNode,Core.PiNode,
                                 Core.UpsilonNode} && continue
                    sj isa Expr && sj.head in (:leave, :pop_exception,
                                               :code_coverage_effect, :meta) && continue
                    throw(CompileError("statement after :leave in the same block"))
                end
            end
        end
        for succ in ir.cfg.blocks[b].succs
            S2 = out
            if term isa Core.EnterNode
                # fallthrough enters the protected region; the catch edge
                # keeps the outer stack
                S2 = succ == term.catch_dest ? out : vcat(out, [(term.catch_dest, b)])
            end
            if stacks[succ] === nothing
                stacks[succ] = S2
                push!(work, succ)
            elseif stacks[succ] != S2
                throw(CompileError("inconsistent handler stacks at block $succ"))
            end
        end
    end
    return any_handler
end

"""Does the rest of basic block `b` (from stmt `i`) inevitably throw?"""
function block_throws_after(fc::FuncCompiler, b::Int, i::Int)
    rng = fc.ir.cfg.blocks[b].stmts
    for j in i:last(rng)
        t = fc.ir.stmts[j][:type]
        widen(t) === Union{} && return true
        s = stmt_at(fc, j)
        s isa Core.ReturnNode && !isdefined(s, :val) && return true
    end
    return false
end

# --- statement emission -------------------------------------------------------

function emit_call!(fc::FuncCompiler, i::Int, ex::Expr)
    rt = type_at(fc, i)
    f = resolve_callee(fc, ex.args[1])
    f === nothing && throw(CompileError("dynamic call at %$i: $(ex.args[1])"))
    args = ex.args[2:end]
    if f === Core.apply_type
        fc.nuses[i] == 0 && return :novalue
        throw(CompileError("apply_type with used result at %$i"))
    end
    if f isa Core.IntrinsicFunction
        name = Symbol(string(f))
        if _is_i128(widen(rt)) ||
           any(r -> _is_i128(widen(argtype(fc, r))), args)
            emit_i128!(fc, name, widen(rt), args)
            return true
        end
        handler = get(INTRINSIC_HANDLERS, name, nothing)
        handler === nothing && throw(CompileError("unsupported intrinsic $name"))
        handler(fc, rt, args)
        return true
    elseif f === Core.:(===)
        Ta, Tb = argtype(fc, args[1]), argtype(fc, args[2])
        if isghost(Ta) && isghost(Tb)
            emit!(fc, i32_const(Int32(Ta === Tb)))
        elseif isghost(Ta) || isghost(Tb)
            ghostT, valref, valT = isghost(Ta) ? (Ta, args[2], Tb) : (Tb, args[1], Ta)
            vt = valtype_for(fc.mc, valT)
            if vt isa RefType && ghostT === Nothing
                emit_value!(fc, valref)
                emit!(fc, ref_is_null())
            else
                # disjoint: a ghost singleton never equals a non-ghost value
                emit!(fc, i32_const(0))
            end
        else
            ra, rb = scalar_repr(Ta), scalar_repr(Tb)
            if typeintersect(Ta, Tb) === Union{}
                # disjoint runtime types can never be egal
                emit!(fc, i32_const(0))
            elseif ra !== nothing && rb !== nothing
                if ra.isfloat
                    INTRINSIC_HANDLERS[:fpiseq](fc, rt, args)
                else
                    emit_cmp!(fc, "eq", args)
                end
            elseif strip_nothing(Ta) === String && strip_nothing(Tb) === String
                # String egal is CONTENT equality (strings are immutable):
                # null-aware call into the compiled byte-compare helper
                reft = RefType(true, HeapType(gc_string!(fc.mc)))
                ra2 = scratch_local!(fc, reft)
                rb2 = scratch_local!(fc, reft)
                emit_value!(fc, args[1])
                emit!(fc, local_set(ra2))
                emit_value!(fc, args[2])
                emit!(fc, local_set(rb2))
                mi_eq = _str_egal_instance()
                request!(fc.mc, mi_eq)
                emit!(fc, local_get(ra2), ref_is_null(), if_(I32))
                emit!(fc, local_get(rb2), ref_is_null())
                emit!(fc, else_())
                emit!(fc, local_get(rb2), ref_is_null(), if_(I32), i32_const(0))
                emit!(fc, else_(), local_get(ra2), local_get(rb2),
                      Inst(:call, (CallTarget(mi_eq),)))
                emit!(fc, end_(), end_())
            else
                va = valtype_for(fc.mc, Ta)
                vb = valtype_for(fc.mc, Tb)
                va isa RefType && vb isa RefType ||
                    throw(CompileError("=== on $Ta, $Tb"))
                Tm = strip_nothing(Ta)
                if Tm isa DataType && Tm <: Core.GenericMemoryRef
                    # MemoryRef egal: same memory (identity) and same offset
                    mref = gc_memref!(fc.mc, Tm)
                    reft = RefType(true, HeapType(mref))
                    ra2 = scratch_local!(fc, reft)
                    rb2 = scratch_local!(fc, reft)
                    emit_value!(fc, args[1])
                    emit!(fc, local_set(ra2))
                    emit_value!(fc, args[2])
                    emit!(fc, local_set(rb2))
                    emit!(fc, local_get(ra2), struct_get(mref, 0),
                          local_get(rb2), struct_get(mref, 0), ref_eq(),
                          local_get(ra2), struct_get(mref, 1),
                          local_get(rb2), struct_get(mref, 1), Inst(:i32_eq),
                          Inst(:i32_and))
                    return true
                end
                if va == ExternRefT || vb == ExternRefT
                    # egal of host-resident values: route through a host import
                    va == vb || throw(CompileError("=== mixing externref and GC values"))
                    hc = request_hostcall!(fc.mc, (:egal,), ===,
                                           Any[Ta, Tb], Bool)
                    emit_value!(fc, args[1])
                    emit_value!(fc, args[2])
                    emit!(fc, Inst(:call, (hc,)))
                    return true
                end
                if ismutabletype(strip_nothing(Ta)) || ismutabletype(strip_nothing(Tb))
                    emit_value!(fc, args[1])
                    emit_value!(fc, args[2])
                    emit!(fc, ref_eq())
                else
                    # immutable structs: structural egal, null-aware
                    Ts = strip_nothing(Ta)
                    is_gc_struct(Ts) ||
                        throw(CompileError("=== on $Ta unsupported"))
                    reft = RefType(true, HeapType(gc_struct!(fc.mc, Ts).typeidx))
                    ra = scratch_local!(fc, reft)
                    rb = scratch_local!(fc, reft)
                    emit_value!(fc, args[1])
                    emit!(fc, local_set(ra))
                    emit_value!(fc, args[2])
                    emit!(fc, local_set(rb))
                    emit!(fc, local_get(ra), ref_is_null(), if_(I32))
                    emit!(fc, local_get(rb), ref_is_null())
                    emit!(fc, else_())
                    emit!(fc, local_get(rb), ref_is_null(), if_(I32))
                    emit!(fc, i32_const(0))
                    emit!(fc, else_())
                    emit_struct_egal!(fc, Ts, ra, rb)
                    emit!(fc, end_(), end_())
                end
            end
        end
        return true
    elseif f === Core.ifelse
        Tv = widen(rt)
        vt = valtype_for(fc.mc, Tv)
        vt === nothing && return true   # ghost result: no value, no effects
        emit_value_typed!(fc, args[2], Tv)
        emit_value_typed!(fc, args[3], Tv)
        emit_value!(fc, args[1])
        # untyped `select` is restricted to numeric types; references need the
        # typed form `select (result t)`
        emit!(fc, vt isa RefType ? select_t(ValType[vt]) : select())
        return true
    elseif f === Core.getfield || f === Base.getfield
        obj = args[1]
        if obj isa Core.SSAValue && haskey(fc.ssapair, obj.id)
            k = args[2]
            k isa QuoteNode && (k = k.value)
            k isa Integer || throw(CompileError("getfield with non-constant index on checked pair"))
            pair = fc.ssapair[obj.id]
            emit!(fc, local_get(k == 1 ? pair[1] : pair[2]))
            return true
        end
        return emit_getfield!(fc, i, args)
    elseif f === Core.setfield! || f === Base.setfield!
        return emit_setfield!(fc, i, args)
    elseif f === Core.tuple
        TT = widen(rt)
        is_gc_struct(TT) || throw(CompileError("unsupported tuple type $TT"))
        info = gc_struct!(fc.mc, TT)
        for (k, ref) in enumerate(args)
            emit_value_typed!(fc, ref, info.fieldtypes[k])
        end
        emit!(fc, struct_new(info.typeidx))
        return true
    elseif f === Core._apply_iterate
        # `tuple(xs...)` over a container: only the paired
        # `isa(result, Tuple{})` use (kwarg-leftover checks) is supported;
        # the splat itself produces no representable value
        length(args) == 3 && resolve_callee(fc, args[2]) === Core.tuple ||
            throw(CompileError("unsupported call to _apply_iterate at %$i"))
        return :novalue
    elseif f === Core.isa
        Tv = argtype(fc, args[1])
        Tt = args[2] isa GlobalRef ? getglobal(args[2].mod, args[2].name) :
             args[2] isa QuoteNode ? args[2].value : args[2]
        Tt isa Type || throw(CompileError("isa with non-constant type"))
        # `isa(tuple(v...), Tuple{})` from kwarg-leftover checks: emptiness of v
        if Tt === Tuple{} && args[1] isa Core.SSAValue
            def = stmt_at(fc, args[1].id)
            if def isa Expr && def.head === :call && length(def.args) == 4 &&
               resolve_callee(fc, def.args[1]) === Core._apply_iterate &&
               resolve_callee(fc, def.args[3]) === Core.tuple
                cont = def.args[4]
                Tc = argtype(fc, cont)
                if Tc isa DataType && Tc <: Vector && isconcretetype(Tc)
                    vinfo = gc_struct!(fc.mc, Tc)
                    sz = Base.fieldindex(Tc, :size)
                    tinfo = gc_struct!(fc.mc, vinfo.fieldtypes[sz])
                    emit_value!(fc, cont)
                    emit!(fc, struct_get(vinfo.typeidx, vinfo.fieldmap[sz]),
                          struct_get(tinfo.typeidx, 0), Inst(:i64_eqz))
                    return true
                elseif Tc isa DataType && Tc <: Tuple && isconcretetype(Tc)
                    emit!(fc, i32_const(Int32(Tc === Tuple{})))
                    return true
                end
            end
            throw(CompileError("unsupported isa(_, Tuple{}) at %$i"))
        end
        if Tv <: Tt
            emit!(fc, i32_const(1))
        elseif typeintersect(Tv, Tt) === Union{}
            emit!(fc, i32_const(0))
        elseif Tv isa Union && strip_nothing(Tv) !== Tv
            # Union{Nothing,T}: isa reduces to a null check
            other = strip_nothing(Tv)
            emit_value!(fc, args[1])
            if other <: Tt
                emit!(fc, ref_is_null(), Inst(:i32_eqz))
            elseif Tt === Nothing
                emit!(fc, ref_is_null())
            else
                throw(CompileError("isa $Tv -> $Tt unsupported"))
            end
        elseif Tv isa Union && valtype_for(fc.mc, Tv) == RefType(true, AnyHT)
            # anyref union: variant test via ref.test on box/struct types
            if Tt === Nothing
                emit_value!(fc, args[1])
                emit!(fc, ref_is_null())
            else
                members = Any[u for u in Base.uniontypes(Tt isa Union ? Tt : Union{Tt,Union{}})]
                _heap_of(u) = scalar_repr(u) !== nothing ?
                    HeapType(gc_box!(fc.mc, u)) :
                    u === String ? HeapType(gc_string!(fc.mc)) :
                    HeapType(gc_struct!(fc.mc, u).typeidx)
                all(u -> u === Nothing || scalar_repr(u) !== nothing ||
                        u === String || is_gc_struct(u), members) ||
                    throw(CompileError("isa $Tv -> $Tt unsupported"))
                v = scratch_local!(fc, RefType(true, AnyHT))
                emit_value!(fc, args[1])
                emit!(fc, local_set(v))
                first_test = true
                for u in members
                    if u === Nothing
                        emit!(fc, local_get(v), ref_is_null())
                    else
                        emit!(fc, local_get(v), ref_test(_heap_of(u)))
                    end
                    first_test || emit!(fc, Inst(:i32_or))
                    first_test = false
                end
            end
        else
            throw(CompileError("dynamic isa $Tv -> $Tt unsupported"))
        end
        return true
    elseif f === Core.typeassert
        Tt = args[2] isa GlobalRef ? getglobal(args[2].mod, args[2].name) : args[2]
        Tv = argtype(fc, args[1])
        Tt isa Type && Tv <: Tt || throw(CompileError("dynamic typeassert $Tv::$Tt"))
        emit_value!(fc, args[1])
        return true
    elseif f === Core.sizeof
        T = strip_nothing(argtype(fc, args[1]))
        if T === String
            emit_value!(fc, args[1])
            emit!(fc, struct_get(gc_string!(fc.mc), 0), array_len(),
                  Inst(:i64_extend_i32_u))
            return true
        end
        valtype_for(fc.mc, T) == ExternRefT ||
            throw(CompileError("sizeof on wasm-resident type $T"))
        hc = request_hostcall!(fc.mc, (:sizeof, T), Core.sizeof, Any[T], Int64)
        emit_value!(fc, args[1])
        emit!(fc, Inst(:call, (hc,)))
        return true
    elseif f === Core.memorynew
        return emit_memorynew!(fc, i, args)
    elseif f === Core.memoryrefnew
        return emit_memoryrefnew!(fc, i, args)
    elseif f === Core.memoryrefget
        return emit_memoryrefget!(fc, i, args)
    elseif f === Core.memoryrefset!
        return emit_memoryrefset!(fc, i, args)
    elseif f === Core.memoryrefunset!
        # clear the slot (GC hygiene): write the element default
        RT = argtype(fc, args[1])
        mref = gc_memref!(fc.mc, RT)
        MT = fieldtype(RT, :mem)
        arr = gc_array!(fc.mc, MT)
        st = field_storage(fc.mc, MT.parameters[2])
        r = scratch_local!(fc, RefType(true, HeapType(mref)))
        emit_value!(fc, args[1])
        emit!(fc, local_tee(r), struct_get(mref, 0),
              local_get(r), struct_get(mref, 1))
        if st isa RefType
            emit!(fc, ref_null(st.ht))
        elseif st isa PackedType
            emit!(fc, i32_const(0))
        else
            emit!(fc, _const(st, 0))
        end
        emit!(fc, array_set(arr), local_get(r))
        return true
    elseif f === Core.memoryrefoffset
        RT = argtype(fc, args[1])
        mref = gc_memref!(fc.mc, RT)
        emit_value!(fc, args[1])
        emit!(fc, struct_get(mref, 1), Inst(:i64_extend_i32_u),
              i64_const(1), Inst(:i64_add))
        return true
    elseif f === Core.memoryref_isassigned
        RT = argtype(fc, args[1])
        mref = gc_memref!(fc.mc, RT)
        gc_array!(fc.mc, fieldtype(RT, :mem))
        r = scratch_local!(fc, RefType(true, HeapType(mref)))
        emit_value!(fc, args[1])
        emit!(fc, local_tee(r), struct_get(mref, 1),
              local_get(r), struct_get(mref, 0), array_len(),
              Inst(:i32_lt_u))
        return true
    elseif f === Core.throw
        throw(CompileError("unsupported builtin throw"))
    else
        throw(CompileError("unsupported call to $(f) at %$i"))
    end
end

"""`Core.memorynew(Memory{T}, n)`: bounds-guarded `array.new_default`."""
function emit_memorynew!(fc::FuncCompiler, i::Int, args)
    MT = widen(type_at(fc, i))
    arr = gc_array!(fc.mc, MT)
    n = scratch_local!(fc, I64)
    emit_value!(fc, args[2])
    emit!(fc, local_tee(n), i64_const(typemax(Int32)), Inst(:i64_gt_u), if_())
    emit_trap_or_throw!(fc)      # negative or absurd size: Julia throws
    emit!(fc, end_())
    emit!(fc, local_get(n), Inst(:i32_wrap_i64), array_new_default(arr))
    return true
end

"""`memoryrefnew(mem)` and `memoryrefnew(ref, idx, boundscheck)`."""
function emit_memoryrefnew!(fc::FuncCompiler, i::Int, args)
    RT = widen(type_at(fc, i))
    mref = gc_memref!(fc.mc, RT)
    if length(args) == 1
        emit_value!(fc, args[1])
        emit!(fc, i32_const(0), struct_new(mref))
        return true
    end
    length(args) == 3 || throw(CompileError("unsupported memoryrefnew arity"))
    arr = gc_array!(fc.mc, fieldtype(RT, :mem))
    arrt = RefType(true, HeapType(arr))
    ix = scratch_local!(fc, I64)
    mem = scratch_local!(fc, arrt)
    # The base may be a MemoryRef or the Memory itself.
    baseT = strip_nothing(argtype(fc, args[1]))
    if baseT <: GenericMemory
        emit_value!(fc, args[1])
        emit!(fc, local_set(mem))
        # 0-based index in i64 to avoid wraparound: idx - 1
        emit_value!(fc, args[2])
        emit!(fc, i64_const(1), Inst(:i64_sub), local_tee(ix))
    else
        r = scratch_local!(fc, RefType(true, HeapType(mref)))
        emit_value!(fc, args[1])
        emit!(fc, local_tee(r), struct_get(mref, 0), local_set(mem))
        # 0-based new index: ref.idx + (idx - 1)
        emit_value!(fc, args[2])
        emit!(fc, local_get(r), struct_get(mref, 1), Inst(:i64_extend_i32_u),
              Inst(:i64_add), i64_const(1), Inst(:i64_sub), local_tee(ix))
    end
    # trap unless 0 <= newidx <= len (one-past-end refs are legal, access traps)
    emit!(fc, local_get(mem), array_len(),
          Inst(:i64_extend_i32_u), Inst(:i64_gt_u), if_())
    emit_trap_or_throw!(fc)
    emit!(fc, end_())
    emit!(fc, local_get(mem),
          local_get(ix), Inst(:i32_wrap_i64), struct_new(mref))
    return true
end

function _emit_array_get!(fc::FuncCompiler, arr::Int, @nospecialize elT)
    st = field_storage(fc.mc, elT)
    if st isa PackedType
        signed = elT !== Bool && scalar_repr(elT).signed
        emit!(fc, signed ? array_get_s(arr) : array_get_u(arr))
    else
        emit!(fc, array_get(arr))
    end
end

"""`memoryrefget(ref, :not_atomic, boundscheck)`: `array.get` (traps OOB)."""
function emit_memoryrefget!(fc::FuncCompiler, i::Int, args)
    RT = argtype(fc, args[1])
    _check_order(args[2])
    mref = gc_memref!(fc.mc, RT)
    MT = fieldtype(RT, :mem)
    arr = gc_array!(fc.mc, MT)
    r = scratch_local!(fc, RefType(true, HeapType(mref)))
    emit_value!(fc, args[1])
    emit!(fc, local_tee(r), struct_get(mref, 0),
          local_get(r), struct_get(mref, 1))
    _emit_array_get!(fc, arr, MT.parameters[2])
    return true
end

"""`memoryrefset!(ref, v, :not_atomic, boundscheck)`; evaluates to `v`."""
function emit_memoryrefset!(fc::FuncCompiler, i::Int, args)
    RT = argtype(fc, args[1])
    _check_order(args[3])
    mref = gc_memref!(fc.mc, RT)
    MT = fieldtype(RT, :mem)
    arr = gc_array!(fc.mc, MT)
    elT = MT.parameters[2]
    r = scratch_local!(fc, RefType(true, HeapType(mref)))
    emit_value!(fc, args[1])
    emit!(fc, local_tee(r), struct_get(mref, 0),
          local_get(r), struct_get(mref, 1))
    emit_value_typed!(fc, args[2], elT)
    emit!(fc, array_set(arr))
    # the statement's value is the stored value
    emit_value_typed!(fc, args[2], widen(type_at(fc, i)))
    return true
end

function _check_order(@nospecialize ord)
    ord isa QuoteNode && (ord = ord.value)
    ord === :not_atomic ||
        throw(CompileError("atomic memory access unsupported (order $ord)"))
end

"""Byte-wise content comparison backing String egal; compiled INTO wasm
(`ncodeunits`/`codeunit` lower to `array.len`/`array.get_u`)."""
function _str_egal(a::String, b::String)
    na = ncodeunits(a)
    ncodeunits(b) == na || return false
    i = 1
    while i <= na
        codeunit(a, i) == codeunit(b, i) || return false
        i += 1
    end
    return true
end

_str_egal_instance() =
    _site_specialize(which(_str_egal, Tuple{String,String}),
                     Tuple{typeof(_str_egal),String,String})::Core.MethodInstance

"""Specialize `m` at the (narrower) site signature `tt`."""
function _site_specialize(m::Method, @nospecialize(tt))
    tt <: m.sig || return nothing
    env = ccall(:jl_type_intersection_with_env, Any, (Any, Any),
                tt, m.sig)::Core.SimpleVector
    return CC.specialize_method(m, tt, env[2]::Core.SimpleVector)
end

"""Pure type-level computations (no side effects; throwing only on malformed
type arguments that inference would have rejected): safe to drop when dead."""
function _is_pure_typelevel(fc::FuncCompiler, @nospecialize(s))
    s isa Expr || return false
    if s.head === :call
        f = try resolve_callee(fc, s.args[1]) catch; nothing end
        return f === Core.apply_type
    elseif s.head === :invoke
        ci = s.args[1]
        mi = ci isa Core.MethodInstance ? ci :
             ci isa Core.CodeInstance ? ci.def : nothing
        mi isa Core.MethodInstance || return false
        return mi.def.module === Base && mi.def.name === :typejoin
    end
    return false
end

function emit_invoke!(fc::FuncCompiler, i::Int, ex::Expr)
    ci = ex.args[1]
    mi = ci isa Core.MethodInstance ? ci :
         ci isa Core.CodeInstance ? ci.def : nothing
    mi isa Core.MethodInstance ||
        throw(CompileError("invoke without a MethodInstance at %$i"))
    # dead pure type-level computation: emit nothing
    fc.nuses[i] == 0 && _is_pure_typelevel(fc, ex) && return false
    # overlay-method intercepts (pointer-based Base primitives)
    spec = get(INTERCEPTS, mi.def, nothing)
    spec !== nothing && return emit_intercept!(fc, i, ex, mi, spec)
    # kwerr only constructs and throws a MethodError (no side effects); its
    # vararg/NamedTuple signature can neither compile nor cross the offload
    # boundary, so lower it directly to the trap/throw of this throwpoint
    if mi.def.module === Base && mi.def.name === :kwerr
        emit_trap_or_throw!(fc)
        return :dead
    end
    # evaluate arguments typed against the callee signature, so e.g.
    # `nothing` literals become ref.null. A data-carrying callable (closure)
    # is itself the first argument; singleton functions are ghosts.
    sig = Base.unwrap_unionall(mi.specTypes)
    ps = collect(Any, sig.parameters)
    if length(ps) != length(ex.args) - 1 || any(Base.isvarargtype, ps)
        # vararg callee (e.g. print_to_string in string interpolation): offload
        # with a signature specialized to THIS call site's concrete arg list
        isghost(ps[1]) ||
            throw(CompileError("vararg invoke of closure $(ps[1]) unsupported"))
        rt_c = ex.args[1] isa Core.CodeInstance ?
               widen((ex.args[1]::Core.CodeInstance).rettype) :
               widen(method_ir(fc.mc, mi)[2])
        rt_c === Union{} &&
            throw(CompileError("vararg invoke of $(mi) unsupported (always throws)"))
        siteTs = Any[widen(argtype(fc, r)) for r in ex.args[3:end]]
        fobj = ghost_instance(sig.parameters[1])
        key = (mi, (siteTs...,))
        hc = request_hostcall!(fc.mc, key, fobj, siteTs, rt_c)
        for (k, ref) in enumerate(ex.args[3:end])
            emit_value_typed!(fc, ref, siteTs[k])
        end
        emit!(fc, Inst(:call, (hc,)))
        return valtype_for(fc.mc, rt_c) !== nothing
    end
    # Julia's nospecialize heuristic leaves Function-typed parameters abstract
    # when the callee only passes them through (e.g. parse_block(ps, down,
    # mark)); the cached callee body would then dynamically dispatch on them.
    # Re-specialize the callee at this site's concrete singleton types.
    respec = Any[P === Function && isghost(widen(argtype(fc, ex.args[k+1]))) ?
                     widen(argtype(fc, ex.args[k+1])) : P
                 for (k, P) in enumerate(ps)]
    if respec != ps
        mi2 = _site_specialize(mi.def, Tuple{respec...})
        if mi2 !== nothing
            mi, ps = mi2, respec
        end
    end
    # a data-carrying callable (closure over GC state) is itself the first
    # argument; singleton functions are ghosts and emit nothing
    isghost(ps[1]) || emit_value_typed!(fc, ex.args[2], ps[1])
    for (k, ref) in enumerate(ex.args[3:end])
        emit_value_typed!(fc, ref, ps[k+1])
    end
    request!(fc.mc, mi)
    emit!(fc, Inst(:call, (CallTarget(mi),)))
    # Whether a value is now on the stack is decided by the *callee* signature,
    # which assembly derives from method_ir under OUR interpreter — the site's
    # CodeInstance can be foreign with a wider rettype (e.g. `Any`).
    rt_callee = widen(method_ir(fc.mc, mi)[2])
    if rt_callee === Union{}
        # the callee always throws: this is a (catchable) program end point
        emit_trap_or_throw!(fc)
        return :dead
    end
    return valtype_for(fc.mc, rt_callee) !== nothing
end

"""Lower an :invoke of an overlay method (see interp.jl) to a hostcall or a
custom wasm sequence. Returns whether a value was pushed."""
function emit_intercept!(fc::FuncCompiler, i::Int, ex::Expr, mi::Core.MethodInstance,
                         spec::InterceptSpec)
    if spec.kind === :custom
        return spec.emit(fc, i, ex, mi)::Bool
    end
    sig = Base.unwrap_unionall(mi.specTypes)
    ps = collect(Any, sig.parameters)
    length(ps) == length(ex.args) - 1 ||
        throw(CompileError("vararg intercept of $(mi) unsupported"))
    rt = ex.args[1] isa Core.CodeInstance ?
         widen((ex.args[1]::Core.CodeInstance).rettype) :
         widen(method_ir(fc.mc, mi)[2])
    for (k, ref) in enumerate(ex.args[3:end])
        emit_value_typed!(fc, ref, ps[k+1])
    end
    hc = if spec.kind === :import
        imod, iname = spec.emit::Tuple{String,String}
        request_hostcall!(fc.mc, (imod, iname), spec.real,
                          Any[T for T in ps[2:end]], rt; mod=imod, name=iname)
    else
        request_hostcall!(fc.mc, mi, spec.real, Any[T for T in ps[2:end]], rt)
    end
    emit!(fc, Inst(:call, (hc,)))
    return rt !== Union{} && valtype_for(fc.mc, rt) !== nothing
end

"""`codeunit(s::String, i::Int64)`: `array.get_u` on the byte array (traps OOB)."""
function emit_string_codeunit!(fc::FuncCompiler, i::Int, ex::Expr, mi::Core.MethodInstance)
    st = gc_string!(fc.mc)
    arr = gc_array!(fc.mc, Memory{UInt8})
    emit_value!(fc, ex.args[3])
    emit!(fc, struct_get(st, 0))
    emit_value!(fc, ex.args[4])
    emit!(fc, Inst(:i32_wrap_i64), i32_const(1), Inst(:i32_sub), array_get_u(arr))
    return true
end

"""`ncodeunits(s::String)`: `array.len` (as Int64)."""
function emit_string_ncodeunits!(fc::FuncCompiler, i::Int, ex::Expr, mi::Core.MethodInstance)
    emit_value!(fc, ex.args[3])
    emit!(fc, struct_get(gc_string!(fc.mc), 0), array_len(),
          Inst(:i64_extend_i32_u))
    return true
end

"""`_memory_to_string(mem, offset0, n)`: copy `n` bytes starting at 0-based
`offset0` out of a `Memory{UInt8}` into a fresh String byte array."""
function emit_memory_to_string!(fc::FuncCompiler, i::Int, ex::Expr, mi::Core.MethodInstance)
    arr = gc_array!(fc.mc, Memory{UInt8})
    st = gc_string!(fc.mc)
    reft = RefType(true, HeapType(arr))
    rsrc = scratch_local!(fc, reft)
    rdst = scratch_local!(fc, reft)
    nloc = scratch_local!(fc, I32)
    emit_value!(fc, ex.args[3])                     # mem (IS the byte array)
    emit!(fc, local_set(rsrc))
    emit_value!(fc, ex.args[5])                     # n :: Int64
    emit!(fc, Inst(:i32_wrap_i64), local_tee(nloc),
          array_new_default(arr), local_set(rdst),
          local_get(rdst), i32_const(0), local_get(rsrc))
    emit_value!(fc, ex.args[4])                     # offset0 :: Int64
    emit!(fc, Inst(:i32_wrap_i64), local_get(nloc), array_copy(arr, arr),
          local_get(rdst), struct_new(st))
    return true
end

"""`unsafe_copyto!(dest::MemoryRef{T}, src::MemoryRef{T}, n)` as `array.copy`."""
function emit_memref_copy!(fc::FuncCompiler, i::Int, ex::Expr, mi::Core.MethodInstance)
    dest, src, n = ex.args[3], ex.args[4], ex.args[5]
    RT = strip_nothing(argtype(fc, dest))
    mref = gc_memref!(fc.mc, RT)
    arr = gc_array!(fc.mc, fieldtype(RT, :mem))
    reft = RefType(true, HeapType(mref))
    rd = scratch_local!(fc, reft)
    rs = scratch_local!(fc, reft)
    emit_value!(fc, dest)
    emit!(fc, local_set(rd))
    emit_value!(fc, src)
    emit!(fc, local_set(rs))
    emit!(fc, local_get(rd), struct_get(mref, 0),
          local_get(rd), struct_get(mref, 1),
          local_get(rs), struct_get(mref, 0),
          local_get(rs), struct_get(mref, 1))
    emit_value!(fc, n)
    emit!(fc, Inst(:i32_wrap_i64), array_copy(arr, arr))
    emit!(fc, local_get(rd))   # unsafe_copyto! returns dest
    return true
end

"""
Emit structural egal of two immutable-struct refs held in locals `ra`/`rb`
(both known non-null); leaves an i32 boolean. Scalars compare bitwise (floats
via reinterpret — egal is bit equality), mutable/Memory refs by identity,
nested immutable structs recursively.
"""
function emit_struct_egal!(fc::FuncCompiler, @nospecialize(T), ra::Int, rb::Int)
    info = gc_struct!(fc.mc, T)
    pushed = 0
    for k in 1:length(info.fieldtypes)
        FT = info.fieldtypes[k]
        isghost(FT) && continue
        widx = info.fieldmap[k]
        st = field_storage(fc.mc, FT)
        getf = st isa PackedType ?
            ((FT !== Bool && scalar_repr(FT).signed) ?
             struct_get_s(info.typeidx, widx) : struct_get_u(info.typeidx, widx)) :
            struct_get(info.typeidx, widx)
        r = scalar_repr(FT)
        if r !== nothing
            if r.isfloat
                re = r.vt == F64 ? Inst(:i64_reinterpret_f64) : Inst(:i32_reinterpret_f32)
                eq = r.vt == F64 ? Inst(:i64_eq) : Inst(:i32_eq)
                emit!(fc, local_get(ra), getf, re, local_get(rb), getf, re, eq)
            else
                emit!(fc, local_get(ra), getf, local_get(rb), getf,
                      _op(r.vt, "eq"))
            end
        elseif st isa RefType && (FT isa DataType &&
                (ismutabletype(FT) || FT <: GenericMemory))
            emit!(fc, local_get(ra), getf, local_get(rb), getf, ref_eq())
        elseif st isa RefType && FT isa DataType && is_gc_struct(FT) &&
               !ismutabletype(FT)
            fa = scratch_local!(fc, st)
            fb = scratch_local!(fc, st)
            emit!(fc, local_get(ra), getf, local_set(fa),
                  local_get(rb), getf, local_set(fb))
            emit_struct_egal!(fc, FT, fa, fb)
        else
            throw(CompileError("structural === on field $(fieldname(T, k))::$FT of $T"))
        end
        pushed += 1
        pushed > 1 && emit!(fc, Inst(:i32_and))
    end
    pushed == 0 && emit!(fc, i32_const(1))
    return nothing
end

function _const_fieldidx(@nospecialize(To), @nospecialize k)
    k isa QuoteNode && (k = k.value)
    k isa Symbol && (k = Base.fieldindex(To, k))
    k isa Integer || throw(CompileError("non-constant field reference"))
    return Int(k)
end

function emit_getfield!(fc::FuncCompiler, i::Int, args)
    # ghost result (e.g. dynamic getfield on an all-Nothing NamedTuple from
    # kwarg plumbing): no value to produce, nothing to evaluate
    isghost(widen(type_at(fc, i))) && return true
    To = strip_nothing(argtype(fc, args[1]))
    if To isa DataType && To <: GenericMemory
        k = _const_fieldidx(To, args[2])
        k == 1 || throw(CompileError("getfield(::Memory, :ptr) unsupported"))
        gc_array!(fc.mc, To)
        emit_value!(fc, args[1])
        emit!(fc, array_len(), Inst(:i64_extend_i32_u))
        return true
    end
    if To isa DataType && To <: Core.GenericMemoryRef
        k = _const_fieldidx(To, args[2])
        k == Base.fieldindex(To, :mem) ||
            throw(CompileError("getfield(::MemoryRef, :ptr_or_offset) unsupported"))
        mref = gc_memref!(fc.mc, To)
        emit_value!(fc, args[1])
        emit!(fc, struct_get(mref, 0))
        return true
    end
    is_gc_struct(To) || throw(CompileError("getfield on unsupported type $To"))
    info = gc_struct!(fc.mc, To)
    kref = args[2]
    kref isa QuoteNode && (kref = kref.value)
    if !(kref isa Union{Symbol,Integer}) && To <: Union{Tuple,NamedTuple}
        # dynamic index into a homogeneous tuple: bounds check + if-chain
        n = fieldcount(To)
        (n > 0 && allequal(info.fieldtypes)) ||
            throw(CompileError("dynamic getfield on heterogeneous $To"))
        FT = info.fieldtypes[1]
        vt = valtype_for(fc.mc, FT)
        reft = RefType(true, HeapType(info.typeidx))
        o = scratch_local!(fc, reft)
        ix = scratch_local!(fc, I64)
        emit_value!(fc, args[1])
        emit!(fc, local_set(o))
        emit_value!(fc, args[2])
        emit!(fc, local_tee(ix), i64_const(1), Inst(:i64_lt_s),
              local_get(ix), i64_const(n), Inst(:i64_gt_s), Inst(:i32_or), if_())
        emit_trap_or_throw!(fc)
        emit!(fc, end_())
        st = field_storage(fc.mc, FT)
        getk(k) = st isa PackedType ?
            ((FT !== Bool && scalar_repr(FT).signed) ?
             struct_get_s(info.typeidx, info.fieldmap[k]) :
             struct_get_u(info.typeidx, info.fieldmap[k])) :
            struct_get(info.typeidx, info.fieldmap[k])
        for k in 1:n-1
            emit!(fc, local_get(ix), i64_const(k), Inst(:i64_eq), if_(vt))
            emit!(fc, local_get(o), getk(k))
            emit!(fc, else_())
        end
        emit!(fc, local_get(o), getk(n))
        for _ in 1:n-1
            emit!(fc, end_())
        end
        return true
    end
    k = _const_fieldidx(To, args[2])
    FT = info.fieldtypes[k]
    isghost(FT) && return true   # ghost field: no value
    widx = info.fieldmap[k]
    emit_value!(fc, args[1])
    st = field_storage(fc.mc, FT)
    if st isa PackedType
        r = scalar_repr(FT)
        signed = FT !== Bool && r.signed
        emit!(fc, signed ? struct_get_s(info.typeidx, widx) :
                           struct_get_u(info.typeidx, widx))
    else
        emit!(fc, struct_get(info.typeidx, widx))
    end
    return true
end

function emit_setfield!(fc::FuncCompiler, i::Int, args)
    To = strip_nothing(argtype(fc, args[1]))
    is_gc_struct(To) && ismutabletype(To) ||
        throw(CompileError("setfield! on unsupported type $To"))
    info = gc_struct!(fc.mc, To)
    k = _const_fieldidx(To, args[2])
    if Base.isconst(To, k) || Base.isfieldatomic(To, k)
        # Native Julia throws at runtime ("const field ... cannot be changed" /
        # ConcurrencyViolationError for plain writes to atomic fields). Trap to
        # match; everything after is unreachable (stack-polymorphic), so the
        # caller's local.set/drop still validates.
        emit!(fc, unreachable())
        return true
    end
    FT = info.fieldtypes[k]
    if !isghost(FT)
        emit_value!(fc, args[1])
        if _erased_field(fc.mc, FT)
            emit_value_anyref!(fc, args[3])
        else
            emit_value_typed!(fc, args[3], FT)
        end
        emit!(fc, struct_set(info.typeidx, info.fieldmap[k]))
    end
    # setfield! evaluates to the assigned value; re-emit it (pure: ssa/arg/const)
    emit_value_typed!(fc, args[3], widen(type_at(fc, i)))
    return true
end

function emit_new!(fc::FuncCompiler, i::Int, ex::Expr)
    TT = widen(type_at(fc, i))
    is_gc_struct(TT) || throw(CompileError("unsupported :new of $TT"))
    info = gc_struct!(fc.mc, TT)
    length(ex.args) - 1 == length(info.fieldtypes) ||
        throw(CompileError("partially-initialized :new of $TT"))
    for (k, ref) in enumerate(ex.args[2:end])
        FT = info.fieldtypes[k]
        isghost(FT) && continue
        if _erased_field(fc.mc, FT)
            emit_value_anyref!(fc, ref)
        else
            emit_value_typed!(fc, ref, FT)
        end
    end
    emit!(fc, struct_new(info.typeidx))
    return true
end

"""Emit one non-terminator statement; returns false if the block traps here."""
function emit_stmt!(fc::FuncCompiler, b::Int, i::Int)
    s = stmt_at(fc, i)
    rt = type_at(fc, i)

    s === nothing && return true
    s isa Core.PhiNode && return true                  # handled on edges
    s isa Core.PhiCNode && return true                 # value lives in its local
    if s isa Core.UpsilonNode
        # writes the corresponding PhiC's local (exception-edge dataflow)
        if haskey(fc.upsilons, i) && isdefined(s, :val)
            loc, phicidx = fc.upsilons[i]
            emit_value_typed!(fc, s.val, type_at(fc, phicidx))
            emit!(fc, local_set(loc))
        end
        return true
    end
    if s isa Core.PiNode
        fc.ssalocal[i] >= 0 || return true
        Tto = type_at(fc, i)
        vt_to = valtype_for(fc.mc, Tto)
        Tfrom = widen(argtype(fc, s.val))
        # unbox: Pi from Union{Nothing,scalar} refining to the scalar
        bi = Tfrom isa Union ? union_box_info(fc.mc, Tfrom) : nothing
        if bi !== nothing && vt_to isa NumType
            emit_value!(fc, s.val)
            emit!(fc, struct_get(bi[1], 0))   # never null per Pi semantics
            emit_norm!(fc, Tto)
            emit!(fc, local_set(fc.ssalocal[i]))
            return true
        end
        emit_value_typed!(fc, s.val, Tto)
        if vt_to isa RefType && !isghost(Tfrom)
            vt_from = valtype_for(fc.mc, Tfrom)
            vt_from isa RefType && vt_from.ht != vt_to.ht &&
                emit!(fc, ref_cast_null(vt_to.ht))
        end
        emit!(fc, local_set(fc.ssalocal[i]))
        return true
    end
    if s isa GlobalRef || s isa QuoteNode || !(s isa Expr)
        # bare value statement
        fc.ssalocal[i] >= 0 || return true
        emit_value!(fc, s)
        emit!(fc, local_set(fc.ssalocal[i]))
        return true
    end

    ex = s::Expr
    if ex.head in (:code_coverage_effect, :meta, :inbounds, :loopinfo,
                   :gc_preserve_begin, :gc_preserve_end, :aliasscope, :popaliasscope,
                   :leave, :pop_exception)
        return true
    end
    ex.head === :the_exception &&
        throw(CompileError("binding the exception value is not yet supported"))
    if ex.head === :boundscheck
        if fc.ssalocal[i] >= 0
            emit!(fc, i32_const(1), local_set(fc.ssalocal[i]))
        end
        return true
    end
    if ex.head === :throw_undef_if_not
        # if !cond throw UndefVarError (catchable inside try regions)
        emit_value!(fc, ex.args[2])
        emit!(fc, Inst(:i32_eqz), if_())
        emit_throwpoint!(fc, b)
        emit!(fc, end_())
        return true
    end
    if ex.head === :call && haskey(fc.ssapair, i)
        fcallee = resolve_callee(fc, ex.args[1])
        kind, signed = CHECKED_PAIR[Symbol(string(fcallee))]
        vloc, floc = fc.ssapair[i]
        emit_checked!(fc, kind, signed, ex.args[2:end], vloc, floc)
        return true
    end
    if ex.head === :call || ex.head === :invoke || ex.head === :new
        # statements that cannot return: throw (catchable) inside protected
        # regions, trap otherwise
        if rt === Union{}
            emit_throwpoint!(fc, b)
            return false
        end
        pushed = try
            if ex.head === :call
                r = emit_call!(fc, i, ex)
                r === :novalue ? false : !isghost(rt)
            elseif ex.head === :invoke
                r = emit_invoke!(fc, i, ex)
                r === :dead && return false   # callee always throws
                r
            else
                emit_new!(fc, i, ex)
                true
            end
        catch err
            err isa CompileError || rethrow()
            # if this block inevitably throws later, raising here is sound
            if block_throws_after(fc, b, i)
                emit_throwpoint!(fc, b)
                return false
            end
            rethrow()
        end
        if pushed
            if fc.ssalocal[i] >= 0
                emit!(fc, local_set(fc.ssalocal[i]))
            else
                emit!(fc, drop())
            end
        elseif fc.ssalocal[i] >= 0
            throw(CompileError("callee produced no value for stored result at %$i"))
        end
        return true
    end
    if block_throws_after(fc, b, i)
        emit_throwpoint!(fc, b)
        return false
    end
    throw(CompileError("unsupported statement at %$i: $(ex.head)"))
end

"""
A point where Julia would raise an exception: throw the module's exception tag
(catchable by an enclosing handler in the same function) when the block is
protected, else trap. The exception *value* is not materialized yet (payload
is null); handlers that bind it are rejected at `:the_exception`.
"""
function emit_throwpoint!(fc::FuncCompiler, b::Int)
    if fc.handlers[b][1] != 0
        emit!(fc, ref_null(AnyHT), throw_(0))
    else
        emit!(fc, unreachable())
    end
end

"""Emit the phi moves for the edge `src -> dst` (parallel-copy via the stack)."""
function emit_phi_moves!(fc::FuncCompiler, src::Int, dst::Int)
    sets = Int[]
    for i in fc.ir.cfg.blocks[dst].stmts
        s = stmt_at(fc, i)
        s isa Core.PhiNode || break
        k = findfirst(==(Int32(src)), s.edges)
        k === nothing && continue
        isassigned(s.values, k) || continue
        fc.ssalocal[i] >= 0 || continue
        emit_value_typed!(fc, s.values[k], type_at(fc, i); tolerant=true)
        push!(sets, fc.ssalocal[i])
    end
    for l in Iterators.reverse(sets)
        emit!(fc, local_set(l))
    end
end

"""Set `next` to block `t` (0-based in the local) and branch to the dispatch loop."""
function emit_goto!(fc::FuncCompiler, t::Int)
    emit!(fc, i32_const(Int32(t - 1)), local_set(fc.nextlocal), br(fc.depth))
end

function emit_return!(fc::FuncCompiler, node::Core.ReturnNode)
    if !isdefined(node, :val)
        emit!(fc, unreachable())
        return
    end
    rt = widen(fc.rettype)
    if rt !== Union{} && valtype_for(fc.mc, rt) !== nothing
        emit_value_typed!(fc, node.val, rt)
    end
    emit!(fc, return_())
end

function emit_block!(fc::FuncCompiler, b::Int)
    h, eb = fc.handlers[b]
    fc.protected = h != 0
    if h != 0
        # protected region: wrap the block in a try_table whose catch routes
        # to the innermost Julia handler via the dispatcher
        emit!(fc, block(RefType(true, AnyHT)))
        emit!(fc, try_table(nothing, [Catch(0x00, 0, 0)]))
        fc.depth += 2
    end
    _emit_block_body!(fc, b)
    fc.protected = false
    if h != 0
        fc.depth -= 2
        emit!(fc, end_())          # try_table (body always branches away)
        emit!(fc, unreachable())
        emit!(fc, end_())          # catch target: payload on stack
        emit!(fc, drop())          # exception value binding unsupported (v1)
        emit_phi_moves!(fc, eb, h) # catch-header phis see the enter edge
        emit_goto!(fc, h)
    end
end

function _emit_block_body!(fc::FuncCompiler, b::Int)
    blk = fc.ir.cfg.blocks[b]
    rng = blk.stmts
    for i in rng
        reset_scratch!(fc)
        s = stmt_at(fc, i)
        if s isa Core.GotoNode
            emit_phi_moves!(fc, b, s.label)
            emit_goto!(fc, s.label)
            return
        elseif s isa Core.EnterNode
            isdefined(s, :scope) && s.scope !== nothing &&
                throw(CompileError("scoped :enter (try with scope) unsupported"))
            emit_phi_moves!(fc, b, b + 1)
            emit_goto!(fc, b + 1)
            return
        elseif s isa Core.GotoIfNot
            fall, dest = b + 1, s.dest
            emit_value!(fc, s.cond)
            emit!(fc, if_())
            fc.depth += 1
            emit_phi_moves!(fc, b, fall)
            emit_goto!(fc, fall)
            emit!(fc, else_())
            emit_phi_moves!(fc, b, dest)
            emit_goto!(fc, dest)
            fc.depth -= 1
            emit!(fc, end_())
            emit!(fc, unreachable())   # both arms branched
            return
        elseif s isa Core.ReturnNode
            emit_return!(fc, s)
            return
        else
            ok = emit_stmt!(fc, b, i)
            ok || return   # block trapped
        end
    end
    # implicit fallthrough to the next block
    emit_phi_moves!(fc, b, b + 1)
    emit_goto!(fc, b + 1)
end

function compile_function(mc::ModuleCompiler, mi::Core.MethodInstance)
    ir, rettype = method_ir(mc, mi)
    rettype = widen(rettype)
    nargs = length(ir.argtypes)

    fc = FuncCompiler(mc, ir, rettype, 0, fill(-1, nargs), Int[], ValType[],
                      Inst[], 0, -1, Dict{ValType,Vector{Int}}(), Dict{ValType,Int}(),
                      Dict{Int,Tuple{Int,Int}}(), Tuple{Int,Int}[],
                      Dict{Int,Tuple{Int,Int}}(), false, Int[])

    # parameter layout. Vararg methods: the wasm signature carries the
    # *expanded* site arguments (matching call sites and offload imports
    # alike), while the body's IR sees the tail packed into one tuple slot —
    # a prologue below packs the tail params into that tuple.
    params = ValType[]
    va_tail = Tuple{Int,Any}[]   # (wasm param idx or -1 if ghost, element type)
    nfixed = mi.def.isva ? nargs - 1 : nargs
    for n in 1:nfixed
        T = widen(ir.argtypes[n])
        # n == 1 is the callable itself: a wasm param when it carries data
        # (closures over GC state); ghost for singleton functions
        vt = valtype_for(mc, T)
        vt === nothing && continue
        push!(params, vt)
        fc.argmap[n] = length(params) - 1
    end
    if mi.def.isva
        expanded = collect(Any, Base.unwrap_unionall(mi.specTypes).parameters)
        any(Base.isvarargtype, expanded) &&
            throw(CompileError("cannot compile unexpanded vararg signature $(mi.specTypes)"))
        for T in expanded[nargs:end]
            Tw = widen(T)
            vt = valtype_for(mc, Tw)
            if vt === nothing
                push!(va_tail, (-1, Tw))
            else
                push!(params, vt)
                push!(va_tail, (length(params) - 1, Tw))
            end
        end
    end
    fc.nparams = length(params)

    # ssa use counts; then transitively zero out dead pure type-level
    # statements (kwarg-lowering leftovers like `typejoin`/`apply_type` chains
    # that inference keeps only because nothrow isn't provable)
    nst = length(ir.stmts)
    fc.nuses = zeros(Int, nst)
    for j in 1:nst
        for u in CC.userefs(stmt_at(fc, j))
            v = u[]
            v isa Core.SSAValue && (fc.nuses[v.id] += 1)
        end
    end
    for j in nst:-1:1
        fc.nuses[j] == 0 || continue
        _is_pure_typelevel(fc, stmt_at(fc, j)) || continue
        for u in CC.userefs(stmt_at(fc, j))
            v = u[]
            v isa Core.SSAValue && (fc.nuses[v.id] -= 1)
        end
    end

    # ssa locals
    fc.ssalocal = fill(-1, nst)
    for i in 1:nst
        T = type_at(fc, i)
        (T === Union{} || isghost(T)) && continue
        s = stmt_at(fc, i)
        produces = s isa Expr ?
            s.head in (:call, :invoke, :boundscheck, :new) :
            (s isa Core.PhiNode || s isa Core.PiNode || s isa GlobalRef ||
             s isa QuoteNode ||
             !(s isa Union{Core.GotoNode,Core.GotoIfNot,Core.ReturnNode,Nothing}))
        produces || continue
        # checked arithmetic returns (value, overflowed) tuples: two locals
        if s isa Expr && s.head === :call && T isa DataType && T <: Tuple &&
           length(T.parameters) == 2 && T.parameters[2] === Bool
            fcallee = try resolve_callee(fc, s.args[1]) catch; nothing end
            if fcallee isa Core.IntrinsicFunction &&
               haskey(CHECKED_PAIR, Symbol(string(fcallee)))
                er = scalar_repr(T.parameters[1])
                if er !== nothing
                    fc.ssapair[i] = (newlocal!(fc, er.vt), newlocal!(fc, I32))
                    continue
                end
            end
        end
        vt = try
            valtype_for(mc, T)
        catch err
            err isa CompileError || rethrow()
            nothing   # unsupported types get no local; uses will error loudly
        end
        vt === nothing && continue
        fc.ssalocal[i] = newlocal!(fc, vt)
    end
    fc.nextlocal = newlocal!(fc, I32)

    # exception-handler regions and upsilon -> PhiC local routing
    if compute_handlers!(fc)
        mc.eh_used = true
    end
    for i in 1:nst
        s = stmt_at(fc, i)
        s isa Core.PhiCNode || continue
        loc = fc.ssalocal[i]
        loc >= 0 || continue
        for k in 1:length(s.values)
            isassigned(s.values, k) || continue
            v = s.values[k]
            v isa Core.SSAValue && (fc.upsilons[v.id] = (loc, i))
        end
    end

    nblocks = length(ir.cfg.blocks)
    # entry blocks have no phis by construction
    for i in ir.cfg.blocks[1].stmts
        stmt_at(fc, i) isa Core.PhiNode &&
            throw(CompileError("unexpected phi in entry block"))
    end

    # vararg prologue: pack the expanded tail params into the tuple the body
    # IR sees as its last argument slot
    if mi.def.isva
        vaT = widen(ir.argtypes[nargs])
        if !isghost(vaT)
            is_gc_struct(vaT) ||
                throw(CompileError("unsupported vararg tuple type $vaT"))
            info = gc_struct!(mc, vaT)
            length(info.fieldtypes) == length(va_tail) ||
                throw(CompileError("vararg arity mismatch for $(mi)"))
            for (pidx, T) in va_tail
                isghost(T) && continue
                pidx >= 0 ||
                    throw(CompileError("unsupported vararg element type $T"))
                emit!(fc, local_get(pidx))
            end
            valoc = newlocal!(fc, valtype_for(mc, vaT))
            emit!(fc, struct_new(info.typeidx), local_set(valoc))
            fc.argmap[nargs] = valoc
        end
    end

    # prologue: start in block 1 (the `next` local is 0-based)
    emit!(fc, i32_const(0), local_set(fc.nextlocal))
    emit!(fc, loop(nothing))
    for _ in 1:nblocks
        emit!(fc, block(nothing))
    end
    emit!(fc, local_get(fc.nextlocal))
    emit!(fc, br_table(collect(0:nblocks-1), 0))
    for b in 1:nblocks
        emit!(fc, end_())
        fc.depth = nblocks - b
        emit_block!(fc, b)
    end
    emit!(fc, end_())          # loop
    emit!(fc, unreachable())   # all paths return inside the loop

    ftype = mi_signature(mc, mi, rettype)
    func = Func(0, fc.locals, fc.body, string(mi.def.name))
    mc.bodies[mi] = func
    mc.sigs[mi] = ftype
    mc.status[mi] = :compiled
    return nothing
end

# --- module assembly ----------------------------------------------------------

struct WasmCompilation
    wmod::WasmModule
    bytes::Vector{UInt8}
    entry::String
    offloads::Vector{Offload}
    hostconsts::Vector{Pair{String,Any}}   # import name => Julia value
end

"""
    compile_wasm(f, argtypes::Type{<:Tuple}; name=string(f)) -> WasmCompilation

Compile `f` for the given argument types into a wasm module. Callees reachable
through `:invoke` are compiled recursively; callees that cannot be translated
but have scalar signatures become host imports (module `"julia"`), listed in
`result.offloads` for binding by the embedder.
"""
function compile_wasm(@nospecialize(f), @nospecialize(argtypes::Type{<:Tuple});
                      name::String=string(f), exact_engine_imports::Bool=false)
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, Base.get_world_counter())
    (matches === nothing || length(matches) != 1) &&
        throw(CompileError("expected a unique method for $tt"))
    mi = Core.Compiler.specialize_method(matches[1])

    mc = ModuleCompiler()
    request!(mc, mi)
    while !isempty(mc.queue)
        cur = popfirst!(mc.queue)
        mc.status[cur] === :pending || continue
        try
            compile_function(mc, cur)
        catch err0
            err0 isa CompileError || rethrow()
            err = occursin("[while compiling", err0.msg) ? err0 :
                  CompileError(err0.msg * " [while compiling $(cur)]")
            cur === mi && throw(err)   # the entry function itself must compile
            try
                offload!(mc, cur, err)
            catch err2
                err2 isa CompileError || rethrow()
                # only fatal if a live function actually calls this
                mc.status[cur] = :failed
                mc.failures[cur] = err2
            end
        end
    end

    # materialize mutable host constants as wasm globals (may register more
    # GC types, host constants, and further value globals)
    vg_inits = Vector{Inst}[]
    vg_deps = Vector{Vector{Int}}()
    let i = 0
        while i < length(mc.valueglobals)
            i += 1
            sink = ConstSink(mc, Inst[])
            emit_const!(sink, mc.valueglobals[i])
            push!(vg_inits, sink.body)
            deps = Int[]
            for inst in sink.body
                if inst.op === :global_get && inst.imm[1] isa ValueGlobal
                    push!(deps, (inst.imm[1]::ValueGlobal).key)
                end
            end
            push!(vg_deps, deps)
        end
    end
    # topological order: dependencies first
    nvg = length(vg_inits)
    vg_order = Int[]
    vg_state = fill(0, nvg)   # 0 unvisited, 1 visiting, 2 done
    function vg_visit(k)
        vg_state[k+1] == 2 && return
        vg_state[k+1] == 1 && throw(CompileError("cyclic constant graph"))
        vg_state[k+1] = 1
        for d in vg_deps[k+1]
            vg_visit(d)
        end
        vg_state[k+1] = 2
        push!(vg_order, k)
    end
    for k in 0:nvg-1
        vg_visit(k)
    end

    # prune to functions reachable from the entry; collect live offloads
    live = Core.MethodInstance[]
    liveset = Set{Core.MethodInstance}()
    liveoff = Set{Any}()
    stack = [mi]
    while !isempty(stack)
        cur = pop!(stack)
        cur in liveset && continue
        push!(liveset, cur); push!(live, cur)
        for inst in mc.bodies[cur].body
            inst.op === :call || continue
            if inst.imm[1] isa HostCall
                push!(liveoff, (inst.imm[1]::HostCall).key)
                continue
            end
            inst.imm[1] isa CallTarget || continue
            t = (inst.imm[1]::CallTarget).mi
            st = mc.status[t]
            if st === :compiled
                t in liveset || push!(stack, t)
            elseif st === :offload
                push!(liveoff, t)
            else
                throw(get(mc.failures, t, CompileError("unresolved call target $t")))
            end
        end
    end
    sort!(live; by=m -> findfirst(==(m), mc.order))
    offloads = [off for off in mc.offloads if off.key in liveoff]

    # The wasm<->host boundary carries only scalars and externrefs. GC-typed
    # (struct/array ref) params/results would not merely be unusable —
    # wasmtime v45's C API *aborts the process* (wasm_valtype_kind is
    # unimplemented for GC types) when the embedder wraps such an export.
    # Strings are the sanctioned exception: a generated entry wrapper
    # externalizes them (extern.convert_any), so the exported signature is
    # externref and hosts access the bytes via the __str_* helper exports.
    entry_sig = mc.sigs[mi]
    entry_argts = Any[widen(t) for t in
                      collect(Any, Base.unwrap_unionall(mi.specTypes).parameters)]
    entry_rt = widen(method_ir(mc, mi)[2])
    entry_ng = Any[T for T in entry_argts[2:end] if !isghost(T)]
    length(entry_ng) == length(entry_sig.params) ||
        throw(CompileError("entry function $name has an unsupported signature shape"))
    needs_entry_wrapper = entry_rt === String || any(T -> T === String, entry_ng)
    bsig_params = ValType[entry_ng[k] === String ? ExternRefT : entry_sig.params[k]
                          for k in 1:length(entry_ng)]
    bsig_results = ValType[entry_rt === String ? ExternRefT : vt
                           for vt in entry_sig.results]
    for vt in Iterators.flatten((bsig_params, bsig_results))
        vt isa NumType || vt == ExternRefT ||
            throw(CompileError("entry function $name has a GC-reference boundary " *
                               "type ($vt); only i32/i64/f32/f64, String, and " *
                               "host-resident (externref) values can cross the " *
                               "wasm boundary"))
    end

    # GC struct types occupy indices [0, N) as a single rec group, registered
    # before any function-signature types
    isempty(mc.gctypes) || push!(mc.wmod.types, RecGroup(mc.gctypes))

    # the module-wide Julia exception tag (anyref payload), tag index 0
    if mc.eh_used
        tagft = addtype!(mc.wmod, FuncType(ValType[RefType(true, AnyHT)], ValType[]))
        push!(mc.wmod.tags, TagType(tagft))
    end

    # assign final indices: offload imports first, then box-wrappers for
    # nullable-scalar-returning offloads, then compiled funcs
    nimports = length(offloads)
    offidx = Dict{Any,Int}()
    for (k, off) in enumerate(offloads)
        offidx[off.key] = k - 1
        ft = FuncType(ValType[_sym_vt(s) for s in off.params],
                      ValType[_sym_vt(s) for s in off.results])
        if exact_engine_imports && off.mod != "julia"
            # spec-exact engine-builtin signatures: string-returning js-string
            # builtins are typed (ref extern), non-null. Engines with strict
            # (pre-subtyping) builtin checks require the exact type; the
            # nullable default stays bindable through wasmtime's C API.
            ft = FuncType(ft.params,
                          ValType[vt == ExternRefT ? RefType(false, ExternHT) : vt
                                  for vt in ft.results])
        end
        importfunc!(mc.wmod, off.mod, off.name, ft)
    end
    hostconsts = Pair{String,Any}[]
    for (k, v) in enumerate(mc.hostconsts)
        nm = "const_$(k-1)"
        push!(mc.wmod.imports, Import("julia", nm, GlobalType(ExternRefT, false)))
        push!(hostconsts, nm => v)
    end
    wrapped = [off for off in offloads if _offload_needs_wrapper(mc, off)]
    for (k, off) in enumerate(wrapped)
        # calls to this offload target the wrapper instead of the raw import
        offidx[off.key] = nimports + k - 1
    end
    fidx = Dict{Core.MethodInstance,Int}()
    for (k, m) in enumerate(live)
        fidx[m] = nimports + length(wrapped) + k - 1
    end
    # value-global final indices: after the imported host-constant globals.
    # The globals are mutable and null-initialized; a start function
    # materializes them in dependency order (init code may use the full
    # instruction set, e.g. array.new_data from passive data segments).
    vgmap = Dict{Int,Int}()
    for (pos, k) in enumerate(vg_order)
        vgmap[k] = length(hostconsts) + pos - 1
    end
    startbody = Inst[]
    for k in vg_order
        init = vg_inits[k+1]
        patch_valueglobals!(init, vgmap)
        vt = valtype_for(mc, typeof(mc.valueglobals[k+1]))
        push!(mc.wmod.globals, Global(GlobalType(vt, true), [ref_null(vt.ht)]))
        append!(startbody, init)
        push!(startbody, Inst(:global_set, (UInt32(vgmap[k]),)))
    end
    for (k, off) in enumerate(wrapped)
        importidx = findfirst(o -> o === off, offloads) - 1
        push!(mc.wmod.funcs, _make_offload_wrapper(mc, off, UInt32(importidx)))
    end
    for m in live
        func = mc.bodies[m]
        func.typeidx = addtype!(mc.wmod, mc.sigs[m])
        patch_calls!(func.body, fidx, offidx)
        patch_valueglobals!(func.body, vgmap)
        push!(mc.wmod.funcs, func)
    end
    nextidx = nimports + length(wrapped) + length(live)
    # entry wrapper: externalize String params/results at the boundary
    entry_export_idx = fidx[mi]
    if needs_entry_wrapper
        body = Inst[]
        for k in 0:length(entry_ng)-1
            push!(body, local_get(k))
            entry_ng[k+1] === String &&
                push!(body, Inst(:any_convert_extern),
                      ref_cast_null(HeapType(gc_string!(mc))))
        end
        push!(body, Inst(:call, (UInt32(fidx[mi]),)))
        entry_rt === String && push!(body, Inst(:extern_convert_any))
        w = Func(addtype!(mc.wmod, FuncType(bsig_params, bsig_results)),
                 ValType[], body, name * "__boundary")
        push!(mc.wmod.funcs, w)
        entry_export_idx = nextidx
        nextidx += 1
    end
    # String accessors: hosts construct and read wasm strings through these
    # (the externref handles are opaque on the host side)
    if haskey(mc.gcboxes, String)
        st = gc_string!(mc)
        arr = gc_array!(mc, Memory{UInt8})
        cast = (Inst(:any_convert_extern), ref_cast_null(HeapType(st)))
        helpers = [
            ("__str_new", FuncType([I32], [ExternRefT]),
             Inst[local_get(0), array_new_default(arr), struct_new(st),
                  Inst(:extern_convert_any)]),
            ("__str_len", FuncType([ExternRefT], [I32]),
             Inst[local_get(0), cast..., struct_get(st, 0), array_len()]),
            ("__str_get", FuncType([ExternRefT, I32], [I32]),
             Inst[local_get(0), cast..., struct_get(st, 0), local_get(1),
                  array_get_u(arr)]),
            ("__str_set", FuncType([ExternRefT, I32, I32], ValType[]),
             Inst[local_get(0), cast..., struct_get(st, 0), local_get(1),
                  local_get(2), array_set(arr)]),
        ]
        for (hname, ft, hbody) in helpers
            push!(mc.wmod.funcs, Func(addtype!(mc.wmod, ft), ValType[], hbody, hname))
            push!(mc.wmod.exports, Export(hname, :func, nextidx))
            nextidx += 1
        end
    end
    if !isempty(startbody)
        sf = Func(addtype!(mc.wmod, FuncType(ValType[], ValType[])),
                  ValType[], startbody, "__init_constants")
        push!(mc.wmod.funcs, sf)
        mc.wmod.start = UInt32(nextidx)
    end
    push!(mc.wmod.exports, Export(name, :func, entry_export_idx))
    bytes = encode(mc.wmod)
    return WasmCompilation(mc.wmod, bytes, name, offloads, hostconsts)
end

"""
Does an offload need a wasm-side wrapper between call sites and the raw
import? Two cases (composable): a `Union{Nothing,scalar}` return — the wire
carries `(value, present)`, boxed back into the nullable ref — and `String`
params/results — GC-resident inside wasm, externalized on the wire.
"""
_offload_needs_wrapper(mc::ModuleCompiler, off::Offload) =
    union_box_info(mc, off.rettype) !== nothing || off.rettype === String ||
    any(T -> T === String, off.argtypes)

function _make_offload_wrapper(mc::ModuleCompiler, off::Offload, importidx::UInt32)
    ng = Any[T for T in off.argtypes if !isghost(T)]
    params = ValType[T === String ? RefType(true, HeapType(gc_string!(mc))) :
                     _sym_vt(off.params[k]) for (k, T) in enumerate(ng)]
    body = Inst[]
    for (k, T) in enumerate(ng)
        push!(body, local_get(k - 1))
        T === String && push!(body, Inst(:extern_convert_any))
    end
    push!(body, Inst(:call, (importidx,)))
    bi = union_box_info(mc, off.rettype)
    if bi !== nothing
        box, elT = bi
        np = length(params)
        push!(body, local_set(np + 1))       # present flag (i32, top of stack)
        push!(body, local_set(np))           # value
        push!(body, local_get(np + 1))
        push!(body, if_(RefType(true, HeapType(box))))
        push!(body, local_get(np), struct_new(box))
        push!(body, else_(), ref_null(HeapType(box)), end_())
        results = ValType[RefType(true, HeapType(box))]
        locals = ValType[scalar_repr(elT).vt, I32]
    elseif off.rettype === String
        push!(body, Inst(:any_convert_extern),
              ref_cast_null(HeapType(gc_string!(mc))))
        results = ValType[RefType(true, HeapType(gc_string!(mc)))]
        locals = ValType[]
    else
        results = ValType[_sym_vt(s) for s in off.results]
        locals = ValType[]
    end
    return Func(addtype!(mc.wmod, FuncType(params, results)), locals, body,
                "wrap_" * off.name)
end

_sym_vt(s::Symbol) = s === :i64 ? I64 : s === :i32 ? I32 : s === :f64 ? F64 :
                     s === :f32 ? F32 : s === :externref ? ExternRefT :
                     error("unknown boundary kind $s")

function patch_calls!(body::Vector{Inst}, fidx::Dict{Core.MethodInstance,Int},
                      offidx::Dict{Any,Int})
    for (k, inst) in enumerate(body)
        inst.op === :call || continue
        if inst.imm[1] isa HostCall
            body[k] = Inst(:call, (UInt32(offidx[(inst.imm[1]::HostCall).key]),))
        elseif inst.imm[1] isa CallTarget
            mi = (inst.imm[1]::CallTarget).mi
            idx = haskey(fidx, mi) ? fidx[mi] : offidx[mi]
            body[k] = Inst(:call, (UInt32(idx),))
        end
    end
end

function patch_valueglobals!(body::Vector{Inst}, vgmap::Dict{Int,Int})
    for (k, inst) in enumerate(body)
        inst.op === :global_get && inst.imm[1] isa ValueGlobal || continue
        body[k] = Inst(:global_get, (UInt32(vgmap[(inst.imm[1]::ValueGlobal).key]),))
    end
end

"""
    offload_imports(comp::WasmCompilation)

The host imports required by `comp`, as tuples
`(mod, name, params, results, callable)` where `callable` accepts and returns
wire-level scalars. Bind each as a host function before instantiating.
"""
function offload_imports(comp::WasmCompilation)
    return [(off.mod, off.name, off.params, off.results, _offload_thunk(off))
            for off in comp.offloads]
end

"""
Host-side String codec for boundary crossings, set by the embedder after
instantiation: a NamedTuple `(tostring = handle -> String, fromstring =
String -> handle)` where handles are whatever the embedding surfaces for
externref values. The wasmtime path builds one over the module's `__str_*`
exports (see WasmtimeRunner examples); JS hosts do their conversions in JS
and never consult this.
"""
const string_bridge = Ref{Any}(nothing)

function _bridge_tostring(h)
    b = string_bridge[]
    b === nothing && throw(WasmCodegenError())
    return b.tostring(h)::String
end
function _bridge_fromstring(s::String)
    b = string_bridge[]
    b === nothing && throw(WasmCodegenError())
    return b.fromstring(s)
end
struct WasmCodegenError <: Exception end
Base.showerror(io::IO, ::WasmCodegenError) =
    print(io, "a String crossed the offload boundary but " *
              "WasmCodegen.string_bridge[] is unset; set it from the " *
              "instance's __str_* exports after instantiation")

function _offload_thunk(off::Offload)
    f, ats, rt = off.func, off.argtypes, off.rettype
    kinds = off.params
    function thunk(wireargs...)
        # Reassemble the full positional argument list: ghost parameters (e.g.
        # singleton function arguments in keyword-sorter methods) are not on the
        # wire and are reconstructed from their types. :externref values arrive
        # as the Julia objects themselves (or, for String, as opaque wasm-string
        # handles decoded through the string bridge); scalars arrive as wire
        # types.
        jlargs = Any[]
        wi = 1
        for T in ats
            if isghost(T)
                push!(jlargs, ghost_instance(T))
            else
                v = wireargs[wi]
                push!(jlargs, kinds[wi] !== :externref ? from_wire(T, v) :
                              T === String ? _bridge_tostring(v) : v)
                wi += 1
            end
        end
        ret = f(jlargs...)
        (isghost(rt) || rt === Union{}) && return nothing
        isempty(off.results) && return nothing
        if length(off.results) == 2 && rt isa Union
            # nullable-scalar return: (value, present-flag)
            other = strip_nothing(rt)
            ret === nothing && return (_wire_zero(other), Int32(0))
            return (to_wire(other, ret), Int32(1))
        end
        off.results[1] === :externref || return to_wire(rt, ret)
        return rt === String ? _bridge_fromstring(ret::String) : ret
    end
    return thunk
end

_wire_zero(@nospecialize T) = T === Char ? Int32(0) : to_wire(T, zero(T))
