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

struct Offload
    mi::Core.MethodInstance
    func::Any                  # the callable (singleton instance)
    argtypes::Vector{Any}      # non-ghost Julia argument types
    rettype::Any
    params::Vector{Symbol}
    results::Vector{Symbol}
    name::String
end

mutable struct ModuleCompiler
    wmod::WasmModule
    order::Vector{Core.MethodInstance}            # discovery order of compiled funcs
    status::Dict{Core.MethodInstance,Symbol}      # :pending / :compiled / :offload
    bodies::Dict{Core.MethodInstance,Func}
    sigs::Dict{Core.MethodInstance,FuncType}
    offloads::Vector{Offload}
    offload_ids::Dict{Core.MethodInstance,Int}
    queue::Vector{Core.MethodInstance}
    failures::Dict{Core.MethodInstance,CompileError}
end
ModuleCompiler() = ModuleCompiler(WasmModule(), Core.MethodInstance[],
                                  Dict(), Dict(), Dict(), Offload[], Dict(),
                                  Core.MethodInstance[], Dict())

widen(@nospecialize t) = CC.widenconst(t)

"""IR for a method instance at full optimization."""
function method_ir(mi::Core.MethodInstance)
    matches = Base.code_ircode_by_type(mi.specTypes)
    length(matches) == 1 ||
        throw(CompileError("expected unique method match for $(mi.specTypes)"))
    return matches[1]   # (IRCode, rettype)
end

function mi_signature(mi::Core.MethodInstance, @nospecialize(rettype))
    sig = Base.unwrap_unionall(mi.specTypes)
    argts = collect(Any, sig.parameters)
    params = ValType[]
    for T in argts[2:end]
        isghost(T) && continue
        push!(params, wasm_valtype(T))
    end
    results = ValType[]
    if !isghost(rettype) && rettype !== Union{}
        push!(results, wasm_valtype(rettype))
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
    args = Any[T for T in argts[2:end] if !isghost(T)]
    params = Symbol[]
    for T in args
        k = valkind_sym(T)
        k === nothing && throw(CompileError("cannot offload $(mi): argument type $T"))
        push!(params, k)
    end
    results = Symbol[]
    if !isghost(rettype) && rettype !== Union{}
        k = valkind_sym(rettype)
        k === nothing && throw(CompileError("cannot offload $(mi): return type $rettype"))
        push!(results, k)
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
    scratch::Dict{NumType,Vector{Int}}
    scratch_used::Dict{NumType,Int}
    ssapair::Dict{Int,Tuple{Int,Int}}   # ssa idx -> (value, flag) locals for
                                        # checked-arithmetic tuple results
end

emit!(fc::FuncCompiler, insts::Inst...) = append!(fc.body, insts)

function newlocal!(fc::FuncCompiler, vt::ValType)
    push!(fc.locals, vt)
    return fc.nparams + length(fc.locals) - 1
end

function scratch_local!(fc::FuncCompiler, vt::NumType)
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
        emit!(fc, i32_const(reinterpret(Int32, UInt32(v))))
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
        if isghost(Ta) || isghost(Tb)
            emit!(fc, i32_const(Int32(Ta === Tb)))
        else
            ra, rb = scalar_repr(Ta), scalar_repr(Tb)
            (ra === nothing || rb === nothing) &&
                throw(CompileError("=== on non-scalars $Ta, $Tb"))
            if ra.isfloat
                INTRINSIC_HANDLERS[:fpiseq](fc, rt, args)
            else
                emit_cmp!(fc, "eq", args)
            end
        end
        return true
    elseif f === Core.ifelse
        Tv = widen(rt)
        emit_value!(fc, args[2])
        emit_value!(fc, args[3])
        emit_value!(fc, args[1])
        emit!(fc, select())
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
        throw(CompileError("getfield on unsupported value at %$i"))
    elseif f === Core.throw
    else
        throw(CompileError("unsupported call to $(f) at %$i"))
    end
end

function emit_invoke!(fc::FuncCompiler, i::Int, ex::Expr)
    ci = ex.args[1]
    mi = ci isa Core.MethodInstance ? ci :
         ci isa Core.CodeInstance ? ci.def : nothing
    mi isa Core.MethodInstance ||
        throw(CompileError("invoke without a MethodInstance at %$i"))
    # evaluate arguments (skipping the function-value slot and ghosts)
    sig = Base.unwrap_unionall(mi.specTypes)
    Base.issingletontype(sig.parameters[1]) ||
        throw(CompileError("invoke of non-singleton callable $(sig.parameters[1])"))
    for ref in ex.args[3:end]
        isghost(argtype(fc, ref)) && continue
        emit_value!(fc, ref)
    end
    request!(fc.mc, mi)
    emit!(fc, Inst(:call, (CallTarget(mi),)))
    return true
end

"""Emit one non-terminator statement; returns false if the block traps here."""
function emit_stmt!(fc::FuncCompiler, b::Int, i::Int)
    s = stmt_at(fc, i)
    rt = type_at(fc, i)

    s === nothing && return true
    s isa Core.PhiNode && return true                  # handled on edges
    if s isa Core.PiNode
        fc.ssalocal[i] >= 0 || return true
        emit_value!(fc, s.val)
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
                   :gc_preserve_begin, :gc_preserve_end, :aliasscope, :popaliasscope)
        return true
    end
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
    if ex.head === :call || ex.head === :invoke
        # statements that cannot return: evaluate as a trap point
        if rt === Union{}
            emit!(fc, unreachable())
            return false
        end
        try
            ex.head === :call ? emit_call!(fc, i, ex) : emit_invoke!(fc, i, ex)
        catch err
            err isa CompileError || rethrow()
            # if this block inevitably throws later, trapping here is sound
            if block_throws_after(fc, b, i)
                emit!(fc, unreachable())
                return false
            end
            rethrow()
        end
        if isghost(rt)
            # ghost result: nothing on stack
        elseif fc.ssalocal[i] >= 0
            emit!(fc, local_set(fc.ssalocal[i]))
        else
            emit!(fc, drop())
        end
        return true
    end
    if block_throws_after(fc, b, i)
        emit!(fc, unreachable())
        return false
    end
    throw(CompileError("unsupported statement at %$i: $(ex.head)"))
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
        emit_value!(fc, s.values[k])
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
    if !(isghost(rt) || rt === Union{})
        emit_value!(fc, node.val)
    end
    emit!(fc, return_())
end

function emit_block!(fc::FuncCompiler, b::Int)
    blk = fc.ir.cfg.blocks[b]
    rng = blk.stmts
    for i in rng
        reset_scratch!(fc)
        s = stmt_at(fc, i)
        if s isa Core.GotoNode
            emit_phi_moves!(fc, b, s.label)
            emit_goto!(fc, s.label)
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
                      Inst[], 0, -1, Dict{NumType,Vector{Int}}(), Dict{NumType,Int}(),
                      Dict{Int,Tuple{Int,Int}}())

    # parameter layout
    params = ValType[]
    for n in 1:nargs
        T = widen(ir.argtypes[n])
        n == 1 && (isghost(T) || throw(CompileError("closure callee with fields: $T"))) &&
            continue
        isghost(T) && continue
        push!(params, wasm_valtype(T))
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
        r = scalar_repr(T)
        if r === nothing
            # checked arithmetic returns (value, overflowed) tuples: two locals
            if s isa Expr && s.head === :call && T isa DataType && T <: Tuple &&
               length(T.parameters) == 2 && T.parameters[2] === Bool
                fcallee = resolve_callee(fc, s.args[1])
                if fcallee isa Core.IntrinsicFunction &&
                   haskey(CHECKED_PAIR, Symbol(string(fcallee)))
                    er = scalar_repr(T.parameters[1])
                    er === nothing && continue
                    fc.ssapair[i] = (newlocal!(fc, er.vt), newlocal!(fc, I32))
                end
            end
            continue   # other non-scalars get no locals; uses will error loudly
        end
        fc.ssalocal[i] = newlocal!(fc, r.vt)
    end
    fc.nextlocal = newlocal!(fc, I32)

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

    ftype = mi_signature(mi, rettype)
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
    liveoff = Set{Core.MethodInstance}()
    stack = [mi]
    while !isempty(stack)
        cur = pop!(stack)
        cur in liveset && continue
        push!(liveset, cur); push!(live, cur)
        for inst in mc.bodies[cur].body
            inst.op === :call && inst.imm[1] isa CallTarget || continue
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
    offloads = [off for off in mc.offloads if off.mi in liveoff]

    # assign final indices: offload imports first, then compiled funcs
    nimports = length(offloads)
    offidx = Dict{Core.MethodInstance,Int}()
    for (k, off) in enumerate(offloads)
        offidx[off.mi] = k - 1
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

_sym_vt(s::Symbol) = s === :i64 ? I64 : s === :i32 ? I32 : s === :f64 ? F64 : F32

function patch_calls!(body::Vector{Inst}, fidx::Dict{Core.MethodInstance,Int},
                      offidx::Dict{Core.MethodInstance,Int})
    for (k, inst) in enumerate(body)
        inst.op === :call && inst.imm[1] isa CallTarget || continue
        mi = (inst.imm[1]::CallTarget).mi
        idx = haskey(fidx, mi) ? fidx[mi] : offidx[mi]
        body[k] = Inst(:call, (UInt32(idx),))
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
    function thunk(wireargs...)
        jlargs = Any[from_wire(T, v) for (T, v) in zip(ats, wireargs)]
        ret = f(jlargs...)
        (isghost(rt) || rt === Union{}) && return nothing
        return to_wire(rt, ret)
    end
    return thunk
end
