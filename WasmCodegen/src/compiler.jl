# The IRCode -> wasm compiler.
#
# CFG lowering uses a dispatcher loop: a `next`-block local, the basic blocks
# as a ladder of nested wasm blocks, and a br_table at the loop head. This is
# correct for arbitrary (even irreducible) control flow; structured relooping
# is a planned optimization.
#
# SSA values live in wasm locals; phi nodes are resolved with parallel-copy
# semantics on the edges (push all incoming values, then set in reverse).

const CC = Core.Compiler

"""Placeholder call target patched to a final function index after the worklist drains."""
struct CallTarget
    mi::Core.MethodInstance
end

"""Call to an auto-generated host import for a builtin on host-resident values."""
struct HostCall
    key::Any    # e.g. (:sizeof, String)
end

struct Offload
    key::Any                   # MethodInstance, or a builtin HostCall key
    func::Any                  # the callable (singleton instance)
    argtypes::Vector{Any}      # Julia argument types (ghosts reconstructed in thunk)
    rettype::Any
    params::Vector{Symbol}
    results::Vector{Symbol}
    name::String
end

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
    eh_used::Bool                                 # some function has try/catch
end
ModuleCompiler() = ModuleCompiler(WasmModule(), Core.MethodInstance[],
                                  Dict(), Dict(), Dict(), Offload[], Dict(),
                                  Core.MethodInstance[], Dict(),
                                  SubType[], IdDict{Any,GCStructInfo}(),
                                  IdDict{Any,Int}(), IdDict{Any,Int}(), false)

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

"""Storage type for a struct field of Julia type `T` (packed sub-words)."""
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
    vt = valtype_for(mc, T)
    vt === nothing && throw(CompileError("ghost field type $T should be skipped"))
    return vt
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
        st = field_storage(mc, FT)
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
    if T isa Union
        U = Base.uniontypes(T)
        if length(U) == 2 && Nothing in U
            other = U[1] === Nothing ? U[2] : U[1]
            if is_gc_struct(other)
                return RefType(true, HeapType(gc_struct!(mc, other).typeidx))
            end
        end
        throw(CompileError("unsupported union type $T"))
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
"""
function request_hostcall!(mc::ModuleCompiler, key, func, argtypes::Vector{Any},
                           @nospecialize rettype)
    if !haskey(mc.offload_ids, key)
        params = Symbol[offload_kind(mc, T) for T in argtypes if !isghost(T)]
        results = Symbol[]
        isghost(rettype) || rettype === Union{} || push!(results, offload_kind(mc, rettype))
        name = "host_$(length(mc.offloads))_$(key isa Tuple ? key[1] : key)"
        push!(mc.offloads, Offload(key, func, argtypes, rettype, params, results, name))
        mc.offload_ids[key] = length(mc.offloads) - 1
    end
    return HostCall(key)
end

"""Boundary kind for offloaded signatures: scalar kinds or `:externref`."""
function offload_kind(mc::ModuleCompiler, @nospecialize T)
    k = valkind_sym(T)
    k === nothing || return k
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

"""IR for a method instance at full optimization."""
function method_ir(mi::Core.MethodInstance)
    matches = Base.code_ircode_by_type(mi.specTypes)
    length(matches) == 1 ||
        throw(CompileError("expected unique method match for $(mi.specTypes)"))
    return matches[1]   # (IRCode, rettype)
end

function mi_signature(mc::ModuleCompiler, mi::Core.MethodInstance, @nospecialize(rettype))
    sig = Base.unwrap_unionall(mi.specTypes)
    argts = collect(Any, sig.parameters)
    params = ValType[]
    for T in argts[2:end]
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
    Base.issingletontype(ftype) ||
        throw(CompileError("cannot offload non-singleton callee $ftype ($(sprint(showerror, why)))"))
    _, rettype = method_ir(mi)
    rettype = widen(rettype)
    args = Any[T for T in argts[2:end]]   # full list; ghosts reconstructed in the thunk
    params, results = try
        (Symbol[offload_kind(mc, T) for T in args if !isghost(T)],
         (!isghost(rettype) && rettype !== Union{}) ? [offload_kind(mc, rettype)] : Symbol[])
    catch err
        err isa CompileError || rethrow()
        throw(CompileError("cannot offload $(mi): $(err.msg); " *
                           "original failure: $(sprint(showerror, why))"))
    end
    name = "offload_$(length(mc.offloads))_$(mi.def.name)"
    push!(mc.offloads, Offload(mi, ftype.instance, args, rettype, params, results, name))
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

"""Emit a constant for a Julia value."""
function emit_const!(fc::FuncCompiler, @nospecialize v)
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
    else
        throw(CompileError("unsupported constant $v::$T"))
    end
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
"""
function emit_value_typed!(fc::FuncCompiler, @nospecialize(ref), @nospecialize(T))
    vt = valtype_for(fc.mc, T)
    vt === nothing && return            # ghost context: no value at all
    if vt isa RefType && isghost(argtype(fc, ref))
        emit!(fc, ref_null(vt.ht))
        return
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
    if f isa Core.IntrinsicFunction
        name = Symbol(string(f))
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
            if ra !== nothing && rb !== nothing
                if ra.isfloat
                    INTRINSIC_HANDLERS[:fpiseq](fc, rt, args)
                else
                    emit_cmp!(fc, "eq", args)
                end
            else
                va = valtype_for(fc.mc, Ta)
                vb = valtype_for(fc.mc, Tb)
                va isa RefType && vb isa RefType ||
                    throw(CompileError("=== on $Ta, $Tb"))
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
                ismutabletype(strip_nothing(Ta)) || ismutabletype(strip_nothing(Tb)) ||
                    throw(CompileError("=== (structural egal) on immutable structs $Ta"))
                emit_value!(fc, args[1])
                emit_value!(fc, args[2])
                emit!(fc, ref_eq())
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
    elseif f === Core.isa
        Tv = argtype(fc, args[1])
        Tt = args[2] isa GlobalRef ? getglobal(args[2].mod, args[2].name) :
             args[2] isa QuoteNode ? args[2].value : args[2]
        Tt isa Type || throw(CompileError("isa with non-constant type"))
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

function emit_invoke!(fc::FuncCompiler, i::Int, ex::Expr)
    ci = ex.args[1]
    mi = ci isa Core.MethodInstance ? ci :
         ci isa Core.CodeInstance ? ci.def : nothing
    mi isa Core.MethodInstance ||
        throw(CompileError("invoke without a MethodInstance at %$i"))
    # evaluate arguments (skipping the function-value slot) typed against the
    # callee signature, so e.g. `nothing` literals become ref.null
    sig = Base.unwrap_unionall(mi.specTypes)
    Base.issingletontype(sig.parameters[1]) ||
        throw(CompileError("invoke of non-singleton callable $(sig.parameters[1])"))
    ps = collect(Any, sig.parameters)
    length(ps) == length(ex.args) - 1 ||
        throw(CompileError("vararg invoke of $(mi) unsupported"))
    for (k, ref) in enumerate(ex.args[3:end])
        emit_value_typed!(fc, ref, ps[k+1])
    end
    request!(fc.mc, mi)
    emit!(fc, Inst(:call, (CallTarget(mi),)))
    # Whether a value is now on the stack is decided by the *callee* signature:
    # the call-site statement type can be wider (e.g. `Any` for unused results).
    rt_callee = ci isa Core.CodeInstance ? widen(ci.rettype) : widen(method_ir(mi)[2])
    if rt_callee === Union{}
        emit!(fc, unreachable())
        return false
    end
    return valtype_for(fc.mc, rt_callee) !== nothing
end

function _const_fieldidx(@nospecialize(To), @nospecialize k)
    k isa QuoteNode && (k = k.value)
    k isa Symbol && (k = Base.fieldindex(To, k))
    k isa Integer || throw(CompileError("non-constant field reference"))
    return Int(k)
end

function emit_getfield!(fc::FuncCompiler, i::Int, args)
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
        emit_value_typed!(fc, args[3], FT)
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
        emit_value_typed!(fc, ref, info.fieldtypes[k])
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
                emit_call!(fc, i, ex)
                !isghost(rt)
            elseif ex.head === :invoke
                emit_invoke!(fc, i, ex)
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
        emit_value_typed!(fc, s.values[k], type_at(fc, i))
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
    ir, rettype = method_ir(mi)
    rettype = widen(rettype)
    nargs = length(ir.argtypes)

    fc = FuncCompiler(mc, ir, rettype, 0, fill(-1, nargs), Int[], ValType[],
                      Inst[], 0, -1, Dict{ValType,Vector{Int}}(), Dict{ValType,Int}(),
                      Dict{Int,Tuple{Int,Int}}(), Tuple{Int,Int}[],
                      Dict{Int,Tuple{Int,Int}}(), false)

    # parameter layout
    params = ValType[]
    for n in 1:nargs
        T = widen(ir.argtypes[n])
        n == 1 && !isghost(T) &&
            throw(CompileError("closure callee with fields: $T"))
        vt = valtype_for(mc, T)
        vt === nothing && continue
        push!(params, vt)
        fc.argmap[n] = length(params) - 1
    end
    fc.nparams = length(params)

    # ssa locals
    nst = length(ir.stmts)
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
end

"""
    compile_wasm(f, argtypes::Type{<:Tuple}; name=string(f)) -> WasmCompilation

Compile `f` for the given argument types into a wasm module. Callees reachable
through `:invoke` are compiled recursively; callees that cannot be translated
but have scalar signatures become host imports (module `"julia"`), listed in
`result.offloads` for binding by the embedder.
"""
function compile_wasm(@nospecialize(f), @nospecialize(argtypes::Type{<:Tuple});
                      name::String=string(f))
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
        catch err
            err isa CompileError || rethrow()
            cur === mi && rethrow()   # the entry function itself must compile
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

    # The entry function's signature is the wasm<->host boundary: only scalars
    # and externrefs can cross it. GC-typed (struct/array ref) params/results
    # would not merely be unusable — wasmtime v45's C API *aborts the process*
    # (wasm_valtype_kind is unimplemented for GC types) when the embedder wraps
    # such an export. Fail loudly at compile time instead.
    entry_sig = mc.sigs[mi]
    for vt in Iterators.flatten((entry_sig.params, entry_sig.results))
        vt isa NumType || vt == ExternRefT ||
            throw(CompileError("entry function $name has a GC-reference boundary " *
                               "type ($vt); only i32/i64/f32/f64 and host-resident " *
                               "(externref) values can cross the wasm boundary"))
    end

    # GC struct types occupy indices [0, N) as a single rec group, registered
    # before any function-signature types
    isempty(mc.gctypes) || push!(mc.wmod.types, RecGroup(mc.gctypes))

    # the module-wide Julia exception tag (anyref payload), tag index 0
    if mc.eh_used
        tagft = addtype!(mc.wmod, FuncType(ValType[RefType(true, AnyHT)], ValType[]))
        push!(mc.wmod.tags, TagType(tagft))
    end

    # assign final indices: offload imports first, then compiled funcs
    nimports = length(offloads)
    offidx = Dict{Any,Int}()
    for (k, off) in enumerate(offloads)
        offidx[off.key] = k - 1
        importfunc!(mc.wmod, "julia", off.name,
                    FuncType(ValType[_sym_vt(s) for s in off.params],
                             ValType[_sym_vt(s) for s in off.results]))
    end
    fidx = Dict{Core.MethodInstance,Int}()
    for (k, m) in enumerate(live)
        fidx[m] = nimports + k - 1
    end
    for m in live
        func = mc.bodies[m]
        func.typeidx = addtype!(mc.wmod, mc.sigs[m])
        patch_calls!(func.body, fidx, offidx)
        push!(mc.wmod.funcs, func)
    end
    push!(mc.wmod.exports, Export(name, :func, fidx[mi]))
    bytes = encode(mc.wmod)
    return WasmCompilation(mc.wmod, bytes, name, offloads)
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

"""
    offload_imports(comp::WasmCompilation)

The host imports required by `comp`, as tuples
`(mod, name, params, results, callable)` where `callable` accepts and returns
wire-level scalars. Bind each as a host function before instantiating.
"""
function offload_imports(comp::WasmCompilation)
    return [("julia", off.name, off.params, off.results, _offload_thunk(off))
            for off in comp.offloads]
end

function _offload_thunk(off::Offload)
    f, ats, rt = off.func, off.argtypes, off.rettype
    kinds = off.params
    function thunk(wireargs...)
        # Reassemble the full positional argument list: ghost parameters (e.g.
        # singleton function arguments in keyword-sorter methods) are not on the
        # wire and are reconstructed from their types. :externref values arrive
        # as the Julia objects themselves; scalars arrive as wire types.
        jlargs = Any[]
        wi = 1
        for T in ats
            if isghost(T)
                push!(jlargs, T.instance)
            else
                v = wireargs[wi]
                push!(jlargs, kinds[wi] === :externref ? v : from_wire(T, v))
                wi += 1
            end
        end
        ret = f(jlargs...)
        (isghost(rt) || rt === Union{}) && return nothing
        isempty(off.results) && return nothing
        return off.results[1] === :externref ? ret : to_wire(rt, ret)
    end
    return thunk
end
