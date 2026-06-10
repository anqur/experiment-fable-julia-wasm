# Engine / Store / Module / Linker / Instance / Func wrappers.

"""Error from wasmtime itself (compilation, linking, type mismatch, ...)."""
struct WasmtimeError <: Exception
    msg::String
end
Base.showerror(io::IO, e::WasmtimeError) = print(io, "WasmtimeError: ", e.msg)

"""A wasm trap (unreachable, OOB access, integer div by zero, host panic, ...)."""
struct WasmTrap <: Exception
    msg::String
end
Base.showerror(io::IO, e::WasmTrap) = print(io, "WasmTrap: ", e.msg)

function _take_bytevec_msg(vec::Base.RefValue{ByteVec})
    msg = unsafe_string(vec[].data, vec[].size)
    ccall((:wasm_byte_vec_delete, libwasmtime), Cvoid, (Ref{ByteVec},), vec)
    return msg
end

"""Consume a `wasmtime_error_t*`, throwing `WasmtimeError`. No-op for NULL."""
function check_error(err::Ptr{Cvoid})
    err == C_NULL && return nothing
    vec = Ref(ByteVec())
    ccall((:wasmtime_error_message, libwasmtime), Cvoid,
          (Ptr{Cvoid}, Ref{ByteVec}), err, vec)
    msg = _take_bytevec_msg(vec)
    ccall((:wasmtime_error_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), err)
    throw(WasmtimeError(msg))
end

"""Consume a `wasm_trap_t*`, throwing `WasmTrap`. No-op for NULL."""
function check_trap(trap::Ptr{Cvoid})
    trap == C_NULL && return nothing
    vec = Ref(ByteVec())
    ccall((:wasm_trap_message, libwasmtime), Cvoid,
          (Ptr{Cvoid}, Ref{ByteVec}), trap, vec)
    msg = _take_bytevec_msg(vec)
    ccall((:wasm_trap_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), trap)
    throw(WasmTrap(msg))
end

# --- engine -----------------------------------------------------------------

mutable struct Engine
    ptr::Ptr{Cvoid}

    function Engine(; gc::Bool=true, function_references::Bool=true,
                    reference_types::Bool=true, tail_call::Bool=true,
                    exceptions::Bool=true, multi_memory::Bool=true,
                    bulk_memory::Bool=true, multi_value::Bool=true,
                    debug_info::Bool=false)
        cfg = ccall((:wasm_config_new, libwasmtime), Ptr{Cvoid}, ())
        cfg == C_NULL && error("wasm_config_new failed")
        handle = Libdl.dlopen(libwasmtime)
        set(name, v) = ccall(Libdl.dlsym(handle, name), Cvoid, (Ptr{Cvoid}, Bool), cfg, v)
        set(:wasmtime_config_wasm_gc_set, gc)
        set(:wasmtime_config_wasm_function_references_set, function_references)
        set(:wasmtime_config_wasm_reference_types_set, reference_types)
        set(:wasmtime_config_wasm_tail_call_set, tail_call)
        set(:wasmtime_config_wasm_exceptions_set, exceptions)
        set(:wasmtime_config_wasm_multi_memory_set, multi_memory)
        set(:wasmtime_config_wasm_bulk_memory_set, bulk_memory)
        set(:wasmtime_config_wasm_multi_value_set, multi_value)
        set(:wasmtime_config_debug_info_set, debug_info)
        ptr = ccall((:wasm_engine_new_with_config, libwasmtime),
                    Ptr{Cvoid}, (Ptr{Cvoid},), cfg)   # consumes cfg
        ptr == C_NULL && error("wasm_engine_new_with_config failed")
        eng = new(ptr)
        finalizer(eng) do e
            ccall((:wasm_engine_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), e.ptr)
        end
        return eng
    end
end

# --- store ------------------------------------------------------------------

"""
    Store(engine)

A wasmtime store: the unit of wasm state (instances, globals, memories, GC
heap).

# Concurrency contract
A store may be *moved* between threads but must never be *used* concurrently
(wasmtime's `StoreContextMut` is an exclusive borrow; concurrent use corrupts
its GC and aborts the process). All wrapper entry points — `WasmFunc` calls,
`WasmGlobal` get/set, `read(::WasmMemory)`, `store_gc!`, `instantiate`,
`exports` — serialize on the store's internal `ReentrantLock`, so multiple
Julia threads/tasks can safely share a `Store` (their calls execute one at a
time). Same-task re-entrancy (wasm -> host function -> wasm) still works
because the lock is reentrant.

Host functions must **not** yield or block (no I/O, `sleep`, channel/`take!`
operations): a host function suspends mid-wasm-call while holding the store
lock, so another task entering the store would block (or deadlock, if the
host function waits on that task). Even without the lock, wasmtime treats a
second entry from another task as a nested activation and miscomputes stack
limits.
"""
mutable struct Store
    ptr::Ptr{Cvoid}
    context::Ptr{Cvoid}
    engine::Engine
    roots::Vector{Any}   # retains HostFunc boxes of linkers instantiated here
    lock::ReentrantLock  # serializes all wasmtime operations on this store

    function Store(engine::Engine)
        ptr = ccall((:wasmtime_store_new, libwasmtime), Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), engine.ptr, C_NULL, C_NULL)
        ptr == C_NULL && error("wasmtime_store_new failed")
        ctx = ccall((:wasmtime_store_context, libwasmtime), Ptr{Cvoid}, (Ptr{Cvoid},), ptr)
        st = new(ptr, ctx, engine, Any[], ReentrantLock())
        finalizer(st) do s
            ccall((:wasmtime_store_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), s.ptr)
        end
        return st
    end
end

"""The raw `wasmtime_context_t*` of a store."""
context(s::Store) = s.context

"""Force a GC inside the wasm store."""
function store_gc!(s::Store)
    Base.@lock s.lock begin
        # v45 returns a wasmtime_error_t* (e.g. allocation failure)
        err = ccall((:wasmtime_context_gc, libwasmtime), Ptr{Cvoid},
                    (Ptr{Cvoid},), s.context)
        check_error(err)
    end
    return nothing
end

# --- module -----------------------------------------------------------------

mutable struct CompiledModule
    ptr::Ptr{Cvoid}
    engine::Engine

    function CompiledModule(engine::Engine, bytes::Vector{UInt8})
        out = Ref{Ptr{Cvoid}}(C_NULL)
        err = ccall((:wasmtime_module_new, libwasmtime), Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}),
                    engine.ptr, bytes, length(bytes), out)
        check_error(err)
        m = new(out[], engine)
        finalizer(m) do mm
            ccall((:wasmtime_module_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), mm.ptr)
        end
        return m
    end
end

"""
    validate_module(engine, bytes) -> nothing

Throw a `WasmtimeError` if `bytes` is not a valid module under the engine's
enabled features.
"""
function validate_module(engine::Engine, bytes::Vector{UInt8})
    err = ccall((:wasmtime_module_validate, libwasmtime), Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), engine.ptr, bytes, length(bytes))
    check_error(err)
end

# --- values -----------------------------------------------------------------

"""A Julia value bound into a store as a wasm `externref`."""
mutable struct ExternRef
    obj::Any
end

const _VALKIND_SYMS = Dict{UInt8,Symbol}(
    WASM_I32 => :i32, WASM_I64 => :i64, WASM_F32 => :f32, WASM_F64 => :f64,
    WASM_EXTERNREF => :externref, WASM_FUNCREF => :funcref,
)
const _SYM_VALKINDS = Dict{Symbol,UInt8}(v => k for (k, v) in _VALKIND_SYMS)

# wasmtime kinds whose vals carry a GC root that must be wasmtime_val_unroot'ed
_needs_unroot(kind::UInt8) =
    kind == WASMTIME_EXTERNREF || kind == WASMTIME_ANYREF || kind == WASMTIME_EXNREF

# Julia-side retention of `ExternRef` boxes handed to wasmtime. Every
# `wasmtime_externref_new` registers its box here (refcounted — the same box
# may back several wasm GC objects), and the finalizer we pass to wasmtime
# releases it when wasm's GC reclaims the externref or the store is deleted.
# This keeps Julia objects alive exactly as long as wasm can reach them,
# instead of accumulating them in an append-only roots vector.
const _EXTERNREF_TABLE = IdDict{ExternRef,Int}()
const _EXTERNREF_TABLE_LOCK = ReentrantLock()

function _externref_retain(box::ExternRef)
    Base.@lock _EXTERNREF_TABLE_LOCK begin
        _EXTERNREF_TABLE[box] = get(_EXTERNREF_TABLE, box, 0) + 1
    end
    return nothing
end

function _externref_release(box::ExternRef)
    Base.@lock _EXTERNREF_TABLE_LOCK begin
        n = get(_EXTERNREF_TABLE, box, 1) - 1
        n <= 0 ? delete!(_EXTERNREF_TABLE, box) : (_EXTERNREF_TABLE[box] = n)
    end
    return nothing
end

# Finalizer invoked by wasmtime when an externref's host data is reclaimed
# (wasm GC, or store deletion — wasmtime runs finalizers for all live GC
# objects when the store is dropped). Always runs on a Julia-attached thread,
# since every store operation and store finalization happens inside a ccall.
function _externref_finalizer(data::Ptr{Cvoid})
    _externref_release(unsafe_pointer_to_objref(data)::ExternRef)
    return nothing
end

function _externref_new(ctx::Ptr{Cvoid}, obj)::ValUnion
    box = obj isa ExternRef ? obj : ExternRef(obj)
    fin = @cfunction(_externref_finalizer, Cvoid, (Ptr{Cvoid},))
    _externref_retain(box)
    out = Ref(CRef())
    ok = GC.@preserve box ccall((:wasmtime_externref_new, libwasmtime), Bool,
                                (Ptr{Cvoid}, Any, Ptr{Cvoid}, Ref{CRef}),
                                ctx, box, fin, out)
    if !ok
        _externref_release(box)
        throw(WasmtimeError("wasmtime_externref_new failed (is GC enabled?)"))
    end
    return union_ref(out[])
end

function _externref_unwrap(ctx::Ptr{Cvoid}, u::ValUnion)
    r = unwrap_ref(u)
    r.store_id == 0 && return nothing
    rref = Ref(r)
    data = ccall((:wasmtime_externref_data, libwasmtime), Ptr{Cvoid},
                 (Ptr{Cvoid}, Ref{CRef}), ctx, rref)
    data == C_NULL && return nothing
    return (unsafe_pointer_to_objref(data)::ExternRef).obj
end

"""
Convert a Julia value to a `wasmtime_val_t` for the given expected kind. For
`:externref`, creates an owned wasmtime GC root that the caller must release
with `_unroot_val` once the val has been handed to (and used by) wasmtime.
`:funcref` accepts a `WasmFunc` or a raw `CFunc` (as received by host
functions).
"""
function to_cval(ctx::Ptr{Cvoid}, kind::Symbol, x)::CVal
    kind === :i32 && return CVal(WASMTIME_I32, union_i32(Int32(x)))
    kind === :i64 && return CVal(WASMTIME_I64, union_i64(Int64(x)))
    kind === :f32 && return CVal(WASMTIME_F32, union_f32(Float32(x)))
    kind === :f64 && return CVal(WASMTIME_F64, union_f64(Float64(x)))
    if kind === :externref
        x === nothing && return CVal(WASMTIME_EXTERNREF, ValUnion())
        return CVal(WASMTIME_EXTERNREF, _externref_new(ctx, x))
    end
    if kind === :funcref
        x === nothing && return CVal(WASMTIME_FUNCREF, ValUnion())
        cf = x isa WasmFunc ? x.func :
             x isa CFunc    ? x :
             throw(ArgumentError("funcref value must be a WasmFunc (or CFunc), got $(typeof(x))"))
        return CVal(WASMTIME_FUNCREF, union_funcref(cf))
    end
    throw(ArgumentError("unsupported wasm value kind $kind"))
end

"""
Convert a `wasmtime_val_t` to a Julia value. With `unroot=true` the val's GC
root (if any) is released after the payload is extracted. Pass `store` to wrap
funcref values as callable `WasmFunc`s; without a store (host-function
callbacks) funcrefs surface as raw `CFunc`s, which can still be passed back to
wasm through `to_cval`. Non-null anyref/exnref values cannot be represented on
the Julia side and throw a `WasmtimeError` (after unrooting) — silently
collapsing them to a placeholder would fake equality between distinct values.
"""
function from_cval(ctx::Ptr{Cvoid}, v::CVal; unroot::Bool=false,
                   store::Union{Nothing,Store}=nothing)
    if v.kind == WASMTIME_I32
        return unwrap_i32(v.of)
    elseif v.kind == WASMTIME_I64
        return unwrap_i64(v.of)
    elseif v.kind == WASMTIME_F32
        return unwrap_f32(v.of)
    elseif v.kind == WASMTIME_F64
        return unwrap_f64(v.of)
    elseif v.kind == WASMTIME_EXTERNREF
        obj = _externref_unwrap(ctx, v.of)
        unroot && _unroot_val(v)
        return obj
    elseif v.kind == WASMTIME_FUNCREF
        f = unwrap_funcref(v.of)
        f.store_id == 0 && return nothing
        return store === nothing ? f : WasmFunc(store, f)
    elseif v.kind == WASMTIME_ANYREF || v.kind == WASMTIME_EXNREF
        r = unwrap_ref(v.of)
        isnull = r.store_id == 0
        unroot && _unroot_val(v)
        isnull && return nothing
        nm = v.kind == WASMTIME_ANYREF ? "anyref" : "exnref"
        throw(WasmtimeError("non-null $nm values cannot be converted to Julia " *
                            "values; GC-typed results are unsupported at the " *
                            "embedding boundary"))
    end
    throw(WasmtimeError("unsupported result value kind $(v.kind)"))
end

_unroot_val(v::CVal) =
    ccall((:wasmtime_val_unroot, libwasmtime), Cvoid, (Ref{CVal},), Ref(v))

# --- functypes (wasm.h objects, used to declare host functions) -------------

function _new_functype(params::Vector{Symbol}, results::Vector{Symbol})
    function mkvec(kinds)
        ptrs = [ccall((:wasm_valtype_new, libwasmtime), Ptr{Cvoid}, (UInt8,),
                      _SYM_VALKINDS[k]) for k in kinds]
        vec = Ref(ValtypeVec(0, C_NULL))
        ccall((:wasm_valtype_vec_new, libwasmtime), Cvoid,
              (Ref{ValtypeVec}, Csize_t, Ptr{Ptr{Cvoid}}), vec, length(ptrs), ptrs)
        return vec
    end
    pv, rv = mkvec(params), mkvec(results)
    ft = ccall((:wasm_functype_new, libwasmtime), Ptr{Cvoid},
               (Ref{ValtypeVec}, Ref{ValtypeVec}), pv, rv)   # consumes both vecs
    ft == C_NULL && error("wasm_functype_new failed")
    return ft
end

function _functype_kinds(ft::Ptr{Cvoid})
    # KNOWN LIMITATION (wasmtime v45): `wasm_valtype_kind` aborts the process
    # ("not implemented") for GC reference types and v128, so wrapping a
    # function whose signature mentions those cannot be made fail-soft here.
    # WasmCodegen refuses to emit such boundary signatures (CompileError);
    # direct embedders must avoid wrapping GC-typed exports.
    function readvec(p::Ptr{ValtypeVec})
        vec = unsafe_load(p)
        kinds = Symbol[]
        for i in 1:vec.size
            vt = unsafe_load(vec.data, i)
            k = ccall((:wasm_valtype_kind, libwasmtime), UInt8, (Ptr{Cvoid},), vt)
            push!(kinds, get(_VALKIND_SYMS, k, Symbol("unknown_", k)))
        end
        return kinds
    end
    pp = ccall((:wasm_functype_params, libwasmtime), Ptr{ValtypeVec}, (Ptr{Cvoid},), ft)
    rp = ccall((:wasm_functype_results, libwasmtime), Ptr{ValtypeVec}, (Ptr{Cvoid},), ft)
    return readvec(pp), readvec(rp)
end

# --- functions --------------------------------------------------------------

"""A callable export (or funcref) living in a `Store`."""
mutable struct WasmFunc
    func::CFunc
    store::Store
    params::Vector{Symbol}
    results::Vector{Symbol}
end

function WasmFunc(store::Store, func::CFunc)
    ft = ccall((:wasmtime_func_type, libwasmtime), Ptr{Cvoid},
               (Ptr{Cvoid}, Ref{CFunc}), store.context, Ref(func))
    params, results = _functype_kinds(ft)
    ccall((:wasm_functype_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), ft)
    return WasmFunc(func, store, params, results)
end

function (f::WasmFunc)(args...)
    store = f.store
    ctx = store.context
    nargs, nres = length(f.params), length(f.results)
    length(args) == nargs ||
        throw(ArgumentError("wasm function expects $nargs arguments, got $(length(args))"))
    Base.@lock store.lock begin
        cargs = CVal[]
        sizehint!(cargs, nargs)
        cres = CVal[CVal() for _ in 1:nres]
        trap = Ref{Ptr{Cvoid}}(C_NULL)
        err = C_NULL
        try
            for (k, a) in zip(f.params, args)
                push!(cargs, to_cval(ctx, k, a))
            end
            err = ccall((:wasmtime_func_call, libwasmtime), Ptr{Cvoid},
                        (Ptr{Cvoid}, Ref{CFunc}, Ptr{CVal}, Csize_t, Ptr{CVal}, Csize_t,
                         Ref{Ptr{Cvoid}}),
                        ctx, Ref(f.func), cargs, length(cargs), cres, nres, trap)
        finally
            # wasmtime_func_call "does not take ownership of wasmtime_val_t
            # arguments" (func.h): release every GC root we created, even when
            # conversion/call/trap raises — otherwise the root slab leaks.
            for v in cargs
                _needs_unroot(v.kind) && _unroot_val(v)
            end
        end
        check_trap(trap[])
        check_error(err)
        nres == 0 && return nothing
        # results ARE owned by us ("gives ownership of results", func.h)
        vals = [from_cval(ctx, v; unroot=true, store=store) for v in cres]
        return nres == 1 ? vals[1] : Tuple(vals)
    end
end

Base.show(io::IO, f::WasmFunc) =
    print(io, "WasmFunc((", join(f.params, ", "), ") -> (", join(f.results, ", "), "))")

# Host function support: a single C-compatible trampoline dispatches to the
# Julia callable carried in `env`.
mutable struct HostFunc
    f::Any
    params::Vector{Symbol}
    results::Vector{Symbol}
end

# OWNERSHIP CONTRACT (verified against the wasmtime v45 C-API shim,
# crates/c-api/src/{func.rs,val.rs}): the shim OWNS the callback's arg and
# result vals — it unroots the args after the callback returns and unroots the
# results after copying them out. This trampoline must therefore NOT call
# `_unroot_val` on `args` or on the vals it stores into `results`; doing so
# would double-unroot. This invariant is version-sensitive: re-verify it when
# bumping the vendored wasmtime.
function _host_trampoline(env::Ptr{Cvoid}, caller::Ptr{Cvoid},
                          args::Ptr{CVal}, nargs::Csize_t,
                          results::Ptr{CVal}, nresults::Csize_t)::Ptr{Cvoid}
    hf = unsafe_pointer_to_objref(env)::HostFunc
    ctx = ccall((:wasmtime_caller_context, libwasmtime), Ptr{Cvoid},
                (Ptr{Cvoid},), caller)
    try
        jlargs = Any[from_cval(ctx, unsafe_load(args, i)) for i in 1:nargs]
        ret = hf.f(jlargs...)
        if nresults == 1
            unsafe_store!(results, to_cval(ctx, hf.results[1], ret), 1)
        elseif nresults > 1
            vals = ret::Tuple
            for i in 1:Int(nresults)
                unsafe_store!(results, to_cval(ctx, hf.results[i], vals[i]), i)
            end
        end
        return C_NULL
    catch err
        # This handler must never throw: a Julia exception escaping the
        # @cfunction would skip wasmtime's Rust frames, leaving stale
        # trap-handler state that aborts the process on a later trap.
        # `showerror` is user-extensible code, so guard it separately.
        msg = try
            string("host function error: ", sprint(showerror, err))
        catch
            "host function error (showerror itself threw)"
        end
        return ccall((:wasmtime_trap_new, libwasmtime), Ptr{Cvoid},
                     (Ptr{UInt8}, Csize_t), msg, sizeof(msg))
    end
end

# --- linker / instance -------------------------------------------------------

mutable struct Linker
    ptr::Ptr{Cvoid}
    engine::Engine
    roots::Vector{Any}   # HostFunc boxes must outlive the linker

    function Linker(engine::Engine)
        ptr = ccall((:wasmtime_linker_new, libwasmtime), Ptr{Cvoid},
                    (Ptr{Cvoid},), engine.ptr)
        ptr == C_NULL && error("wasmtime_linker_new failed")
        lk = new(ptr, engine, Any[])
        finalizer(lk) do l
            ccall((:wasmtime_linker_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), l.ptr)
        end
        return lk
    end
end

"""
    define_func!(f, linker, mod, name, params, results)

Define import `mod`.`name` as the Julia callable `f`. `params`/`results` are
vectors of `:i32`, `:i64`, `:f32`, `:f64`, `:externref`, `:funcref`. A Julia
exception thrown by `f` becomes a wasm trap carrying the error text.

`f` runs in the middle of a wasm call and must **not** yield or block (no
I/O, `sleep`, channel operations, locks contended with other tasks): the
calling task holds the store lock, and wasmtime cannot tolerate another task
entering the store while the call is suspended. Synchronously calling back
into wasm functions of the same store is fine. Funcref parameters arrive as
raw `CFunc` handles; they can be returned/passed back to wasm as-is, or
wrapped via `WasmFunc(store, cfunc)` if `f` closes over the store.
"""
function define_func!(f, linker::Linker, mod::String, name::String,
                      params::Vector{Symbol}, results::Vector{Symbol})
    hf = HostFunc(f, params, results)
    push!(linker.roots, hf)
    ft = _new_functype(params, results)
    cb = @cfunction(_host_trampoline, Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{CVal}, Csize_t, Ptr{CVal}, Csize_t))
    err = ccall((:wasmtime_linker_define_func, libwasmtime), Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t,
                 Ptr{Cvoid}, Ptr{Cvoid}, Any, Ptr{Cvoid}),
                linker.ptr, mod, sizeof(mod), name, sizeof(name),
                ft, cb, hf, C_NULL)
    ccall((:wasm_functype_delete, libwasmtime), Cvoid, (Ptr{Cvoid},), ft)
    check_error(err)
    return nothing
end

mutable struct WasmGlobal
    global_::CRef   # wasmtime_global_t has the same 24-byte layout
    store::Store
end

function Base.getindex(g::WasmGlobal)
    Base.@lock g.store.lock begin
        out = Ref(CVal())
        ccall((:wasmtime_global_get, libwasmtime), Cvoid,
              (Ptr{Cvoid}, Ref{CRef}, Ref{CVal}), g.store.context, Ref(g.global_), out)
        return from_cval(g.store.context, out[]; unroot=true, store=g.store)
    end
end

const _WASMTIME_KIND_SYMS = Dict{UInt8,Symbol}(
    WASMTIME_I32 => :i32, WASMTIME_I64 => :i64,
    WASMTIME_F32 => :f32, WASMTIME_F64 => :f64,
    WASMTIME_EXTERNREF => :externref, WASMTIME_FUNCREF => :funcref,
)

function Base.setindex!(g::WasmGlobal, x)
    Base.@lock g.store.lock begin
        ctx = g.store.context
        # Determine the global's kind from its *current value*. The static
        # route (wasmtime_global_type + wasm_valtype_kind) aborts the process
        # for GC/v128 types in the v45 C API; the kind byte returned by
        # wasmtime_global_get is correct for every kind.
        cur = Ref(CVal())
        ccall((:wasmtime_global_get, libwasmtime), Cvoid,
              (Ptr{Cvoid}, Ref{CRef}, Ref{CVal}), ctx, Ref(g.global_), cur)
        curkind = cur[].kind
        _needs_unroot(curkind) && _unroot_val(cur[])
        kind = get(_WASMTIME_KIND_SYMS, curkind, nothing)
        kind === nothing &&
            throw(ArgumentError("cannot set wasm global of unsupported kind " *
                                "$curkind (anyref/exnref/v128 globals are not supported)"))
        val = to_cval(ctx, kind, x)
        err = try
            ccall((:wasmtime_global_set, libwasmtime), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ref{CRef}, Ref{CVal}), ctx, Ref(g.global_), Ref(val))
        finally
            # wasmtime_global_set "does not take ownership of any argument"
            # (global.h): release the GC root we created for `val`.
            _needs_unroot(val.kind) && _unroot_val(val)
        end
        check_error(err)
    end
    return x
end

mutable struct WasmMemory
    mem::CRef   # wasmtime_memory_t has the same 24-byte layout
    store::Store
end

"""
    read(m::WasmMemory) -> Vector{UInt8}

The current contents of the linear memory, as an owned copy. (A view into the
store's memory would dangle as soon as the store is freed or the memory grows,
so `read` deliberately pays for the copy.)
"""
function Base.read(m::WasmMemory)
    Base.@lock m.store.lock begin
        GC.@preserve m begin   # keep the Store (and its base pointer) alive
            data = ccall((:wasmtime_memory_data, libwasmtime), Ptr{UInt8},
                         (Ptr{Cvoid}, Ref{CRef}), m.store.context, Ref(m.mem))
            size = ccall((:wasmtime_memory_data_size, libwasmtime), Csize_t,
                         (Ptr{Cvoid}, Ref{CRef}), m.store.context, Ref(m.mem))
            out = Vector{UInt8}(undef, size)
            size == 0 || unsafe_copyto!(pointer(out), data, size)
            return out
        end
    end
end

mutable struct Instance
    instance::CInstance
    store::Store
    linker::Union{Nothing,Linker}
end

"""
    instantiate(linker, store, mod) -> Instance

Instantiate a compiled module, resolving its imports through the linker.
"""
function instantiate(linker::Linker, store::Store, mod::CompiledModule)
    Base.@lock store.lock begin
        out = Ref(CInstance())
        trap = Ref{Ptr{Cvoid}}(C_NULL)
        err = ccall((:wasmtime_linker_instantiate, libwasmtime), Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ref{CInstance}, Ref{Ptr{Cvoid}}),
                    linker.ptr, store.context, mod.ptr, out, trap)
        check_trap(trap[])
        check_error(err)
        # the store must keep host-function roots alive as long as instances run
        push!(store.roots, linker.roots)
        return Instance(out[], store, linker)
    end
end

instantiate(store::Store, mod::CompiledModule) =
    instantiate(Linker(store.engine), store, mod)

function _wrap_extern(store::Store, ext::CExtern)
    if ext.kind == WASMTIME_EXTERN_FUNC
        return WasmFunc(store, unwrap_funcref(ext.of))
    elseif ext.kind == WASMTIME_EXTERN_GLOBAL
        return WasmGlobal(unwrap_ref(ext.of), store)
    elseif ext.kind == WASMTIME_EXTERN_MEMORY
        return WasmMemory(unwrap_ref(ext.of), store)
    end
    return (:extern, ext.kind)   # tables/tags: not yet wrapped
end

"""
    exports(inst::Instance) -> Dict{String,Any}

All exports of an instance, wrapped (`WasmFunc`, `WasmGlobal`, `WasmMemory`).
"""
function exports(inst::Instance)
    store = inst.store
    Base.@lock store.lock begin
        out = Dict{String,Any}()
        i = 0
        while true
            nameptr = Ref{Ptr{UInt8}}(C_NULL)
            namelen = Ref{Csize_t}(0)
            ext = Ref(CExtern())
            ok = ccall((:wasmtime_instance_export_nth, libwasmtime), Bool,
                       (Ptr{Cvoid}, Ref{CInstance}, Csize_t, Ref{Ptr{UInt8}},
                        Ref{Csize_t}, Ref{CExtern}),
                       store.context, Ref(inst.instance), i, nameptr, namelen, ext)
            ok || break
            name = unsafe_string(nameptr[], namelen[])
            out[name] = _wrap_extern(store, ext[])
            i += 1
        end
        return out
    end
end

Base.getindex(inst::Instance, name::AbstractString) = exports(inst)[String(name)]
