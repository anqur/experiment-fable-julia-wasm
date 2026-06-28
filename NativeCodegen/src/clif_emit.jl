# CLIF text emitter for Julia IRCode → Cranelift CLIF.
# Phase 4: loops via phi nodes → CLIF block parameters.

using WasmCodegen: ScalarRepr, scalar_repr, isghost, wasm_valtype

const CLIF_INTR_OPS = Dict{Symbol,String}(
    :add_int=>"iadd", :sub_int=>"isub", :mul_int=>"imul",
    :sdiv_int=>"sdiv", :udiv_int=>"udiv", :srem_int=>"srem", :urem_int=>"urem",
    :neg_int=>"isub 0,", :and_int=>"band", :or_int=>"bor", :xor_int=>"bxor",
    :not_int=>"bxor %s, -1", :shl_int=>"ishl", :lshr_int=>"ushr", :ashr_int=>"sshr",
    :eq_int=>"icmp eq", :ne_int=>"icmp ne", :slt_int=>"icmp slt", :sle_int=>"icmp sle",
    :ugt_int=>"icmp ugt", :uge_int=>"icmp uge",
    :add_float=>"fadd", :sub_float=>"fsub", :mul_float=>"fmul", :div_float=>"fdiv",
    :neg_float=>"fneg", :eq_float=>"fcmp eq", :ne_float=>"fcmp ne",
    :lt_float=>"fcmp lt", :le_float=>"fcmp le",
    :sext_int=>"sextend", :zext_int=>"uextend", :trunc_int=>"ireduce",
    :bitcast=>"bitcast", :sqrt_llvm=>"sqrt", :ceil_llvm=>"ceil",
    :floor_llvm=>"floor", :trunc_llvm=>"trunc", :select_value=>"select",
    :(===)=>"icmp eq",
    :checked_srem_int=>"srem", :checked_sdiv_int=>"sdiv",
    :checked_urem_int=>"urem", :checked_udiv_int=>"udiv",
    :checked_sadd_int=>"iadd", :checked_ssub_int=>"isub", :checked_smul_int=>"imul",
    # Bit ops (unary: result = op arg)
    :ctlz_int=>"clz", :cttz_int=>"ctz", :ctpop_int=>"popcnt",
    :bswap_int=>"bswap",
    # Float conversions & math (will be verified against CLIF spec)
    :abs_float=>"fabs", :reinterpret=>"bitcast",
)

const CLIF_CLIF_TYPE = IdDict{Any,String}(
    Int64=>"i64", UInt64=>"i64", Int32=>"i32", UInt32=>"i32",
    Int16=>"i32", UInt16=>"i32", Int8=>"i32", UInt8=>"i32",
    Bool=>"i32", Char=>"i32", Float64=>"f64", Float32=>"f32",
)

mutable struct CLIFCtx; io::IOBuffer; indent::Int; nextv::Int; end
CLIFCtx() = CLIFCtx(IOBuffer(), 0, 0)
emit(c::CLIFCtx, s) = (write(c.io, repeat("    ", c.indent), s, '\n'); nothing)
emit_raw(c::CLIFCtx, s) = (write(c.io, s); nothing)
freshv(c::CLIFCtx) = "v$(c.nextv += 1)"

clif_t(T) = let t = get(CLIF_CLIF_TYPE, T, nothing)
    t !== nothing && return t
    T isa DataType && Base.ismutabletype(T) && !(T <: Ptr) && return "i64"
    r = scalar_repr(T); r === nothing && throw(CompileError("unsupported CLIF type $T"))
    r.vt == WasmTools.I64 ? "i64" : r.vt == WasmTools.I32 ? "i32" :
    r.vt == WasmTools.F64 ? "f64" : "f32"
end

clif_const(v::Int64)=string(v); clif_const(v::UInt64)=string(v)
clif_const(v::Int32)=string(v); clif_const(v::UInt32)=string(v)
clif_const(v::Bool)=v ? "1" : "0"
clif_const(v::Float64) = _hexfloat(v)
clif_const(v::Float32) = _hexfloat(Float64(v))

# Convert Float64 to CLIF hex float format: e.g. 1.0 -> "0x1.0p0"
function _hexfloat(v::Float64)
    v == 0.0 && return "0x0.0p0"
    bits = reinterpret(UInt64, v)
    sign = (bits >> 63) & 1
    exp = Int((bits >> 52) & 0x7ff) - 1023
    frac = bits & 0x000fffffffffffff
    frac_str = string(frac | 0x0010000000000000, base=16, pad=13)  # 1 + 52 bits = 53 bits = 14 hex digits
    # Remove trailing zeros
    frac_str = replace(frac_str, r"0+$" => "")
    length(frac_str) < 2 && (frac_str *= "0")
    s = sign == 1 ? "-" : ""
    return "$(s)0x$(frac_str[1:1]).$(frac_str[2:end])p$(exp)"
end
clif_const(v::Core.QuoteNode)=clif_const(v.value); clif_const(v)="0"

function _resolve(ssa_v, arg_v, val)
    val isa Core.SSAValue && return get(ssa_v, val.id, "???")
    val isa Core.Argument && (idx=val.n+1; return idx <= length(arg_v) ? arg_v[idx] : "???")
    return clif_const(val)
end

function _to_ssa(ctx, s; isfloat=false)
    is_const = occursin(r"^-?\d+$", s) || occursin(r"^0x[0-9a-fA-F]+$", s) ||
               occursin(r"^-?\d+\.\d+$", s) || occursin(r"^-?\d+\.\d+e[+-]?\d+$", s) ||
               occursin(r"^-?0x[0-9a-fA-F]+\.[0-9a-fA-F]*p[+-]?\d+$", s)
    is_const || return s
    v = freshv(ctx)
    if isfloat
        emit(ctx, "$v = f64const $s")
    else
        emit(ctx, "$v = iconst.i64 $s")
    end
    return v
end

# Unary and pseudo-unary intrinsics that need special handling
const UNARY_INTR = Set{Symbol}([:neg_int, :not_int, :ctlz_int, :cttz_int, :ctpop_int,
    :bswap_int, :abs_float])

function clif_intrinsic(ctx, result, name::Symbol, a, b)
    op = get(CLIF_INTR_OPS, name, nothing)
    op === nothing && return (emit(ctx, "; unhandled $name"); emit(ctx, "$result = 0"))
    # Special unary handlers
    name == :neg_int && return (z=freshv(ctx); emit(ctx, "$z = iconst.i64 0"); emit(ctx, "$result = isub $z, $(_to_ssa(ctx,a))"))
    name == :not_int && return (z=freshv(ctx); emit(ctx, "$z = iconst.i32 -1"); emit(ctx, "$result = bxor $(_to_ssa(ctx,a)), $z"))
    # Generic unary: result = op arg
    if name in UNARY_INTR
        emit(ctx, "$result = $op $(_to_ssa(ctx,a))")
        return
    end
    isfloat = startswith(string(op), "f")
    iscmp = startswith(string(op), "icmp ") || startswith(string(op), "fcmp ")
    ca = _to_ssa(ctx, a; isfloat=false)
    cb = isempty(b) ? b : _to_ssa(ctx, b; isfloat=isfloat)
    if iscmp
        t = freshv(ctx); emit(ctx, "$t = $op $ca, $cb"); emit(ctx, "$result = uextend.i32 $t")
    else
        emit(ctx, "$result = $op $ca, $cb")
    end
end

function emit_clif_function(ir::CC.IRCode, argtypes::Vector{Type}, rettype, entry_name="entry")
    ctx = CLIFCtx()
    real_args = [T for T in argtypes if !isghost(T)]
    param_strs = [clif_t(T) for T in real_args]
    ret_str = (rettype === Nothing || rettype === Union{}) ? "" : " -> $(clif_t(rettype))"
    emit_raw(ctx, "function %$entry_name($(join(param_strs, ", ")))$ret_str {\n")
    ctx.indent += 1
    arg_v = String["",""]; for T in real_args; push!(arg_v, freshv(ctx)); end

    cfg = ir.cfg; nbb = length(cfg.blocks)
    bb_name = Dict{Int,String}(i => "block$(i-1)" for i in 1:nbb)

    # --- Phi nodes → CLIF block parameters ---
    phi_val = Dict{Int,String}()           # phi stmt_idx → CLIF param name
    bb_params = Dict{Int,Vector{Tuple{String,String}}}()  # BB → [(name, type)]
    for i in 1:nbb; bb_params[i] = Tuple{String,String}[]; end
    # Entry block params = function args
    for (k,T) in enumerate(real_args); push!(bb_params[1], (arg_v[k+2], clif_t(T))); end

    for (bi, block) in enumerate(cfg.blocks)
        for si in block.stmts
            e = ir.stmts[si][:stmt]
            if e isa Core.PhiNode || e isa Core.PhiCNode
                pn = freshv(ctx); phi_val[si] = pn
                push!(bb_params[bi], (pn, "i64"))
            end
        end
    end

    emit(ctx, "block0($(join(["$(n): $(t)" for (n,t) in bb_params[1]], ", "))):")
    ctx.indent += 1

    # Terminators
    bb_term = Dict{Int,Tuple}()
    for (bi, block) in enumerate(cfg.blocks)
        lst = ir.stmts[last(block.stmts)][:stmt]
        lst isa Core.GotoNode && (bb_term[bi] = (:goto, lst.label))
        lst isa Core.GotoIfNot && (bb_term[bi] = (:gotoifnot, lst.cond, lst.dest))
        lst isa Core.ReturnNode && (bb_term[bi] = (:return, lst.val))
    end

    ssa_v = Dict{Int,String}()

    for (bi, block) in enumerate(cfg.blocks)
        if bi > 1
            ctx.indent -= 1; emit(ctx, "")
            if isempty(bb_params[bi])
                emit(ctx, "$(bb_name[bi]):")
            else
                emit(ctx, "$(bb_name[bi])($(join(["$(n): $(t)" for (n,t) in bb_params[bi]], ", "))):")
            end
            ctx.indent += 1
        end
        # Pre-bind phi values for this BB
        for si in block.stmts
            e = ir.stmts[si][:stmt]
            (e isa Core.PhiNode || e isa Core.PhiCNode) && (ssa_v[si] = phi_val[si])
        end
        for si in block.stmts
            e = ir.stmts[si][:stmt]
            e isa Core.GotoNode && continue
            e isa Core.GotoIfNot && continue
            e isa Core.ReturnNode && continue
            e isa Core.PhiNode && continue
            e isa Core.PhiCNode && continue
            e isa Core.SSAValue && (ssa_v[si] = ssa_v[e.id]; continue)
            (isa(e, Number) || isa(e, Bool) || e isa Core.QuoteNode) &&
                (v=freshv(ctx); ssa_v[si]=v; emit(ctx, "$v = $(clif_const(e))"); continue)
            if e isa Expr && e.head == :call
                v = freshv(ctx); ssa_v[si] = v; f = e.args[1]
                # getfield
                if f isa Core.GlobalRef && f.name == :getfield
                    obj, field = e.args[2], e.args[3]
                    fn = field isa Core.QuoteNode ? field.value : field
                    so = _resolve(ssa_v, arg_v, obj)
                    T = (obj isa Core.Argument) && (idx=obj.n-2+1; idx>=1 && idx<=length(argtypes)) ? argtypes[idx] : Any
                    if T isa DataType && Base.ismutabletype(T)
                        off = fieldoffset(T, fieldindex(T, fn))
                        vi = freshv(ctx); emit(ctx, "$vi = iconst.i64 $off")
                        vo = freshv(ctx); emit(ctx, "$vo = iadd $so, $vi")
                        emit(ctx, "$v = load.i64 $vo"); continue
                    end
                    emit(ctx, "; getfield unknown"); emit(ctx, "$v = 0"); continue
                end
                # setfield!
                if f isa Core.GlobalRef && f.name == :setfield!
                    obj, field, fv = e.args[2], e.args[3], e.args[4]
                    fn = field isa Core.QuoteNode ? field.value : field
                    so, sv = _resolve(ssa_v, arg_v, obj), _resolve(ssa_v, arg_v, fv)
                    T = (obj isa Core.Argument) && (idx=obj.n-2+1; idx>=1 && idx<=length(argtypes)) ? argtypes[idx] : Any
                    if T isa DataType && Base.ismutabletype(T)
                        off = fieldoffset(T, fieldindex(T, fn))
                        vi = freshv(ctx); emit(ctx, "$vi = iconst.i64 $off")
                        vo = freshv(ctx); emit(ctx, "$vo = iadd $so, $vi")
                        emit(ctx, "store.i64 $sv, $vo"); ssa_v[si] = so; continue
                    end
                    emit(ctx, "; setfield! unknown"); emit(ctx, "$v = 0"); continue
                end
                # Intrinsic
                name = nothing
                f isa Core.IntrinsicFunction && (name = f.name)
                f isa Core.GlobalRef && haskey(CLIF_INTR_OPS, f.name) && (name = f.name)
                name === nothing && (emit(ctx, "; call $f"); emit(ctx, "$v = 0"); continue)
                a1 = length(e.args)>=2 ? e.args[2] : nothing
                a2 = length(e.args)>=3 ? e.args[3] : nothing
                clif_intrinsic(ctx, v, name,
                    a1 !== nothing ? _resolve(ssa_v, arg_v, a1) : "",
                    a2 !== nothing ? _resolve(ssa_v, arg_v, a2) : "")
                continue
            end
            e isa Expr && e.head == :invoke &&
                (v=freshv(ctx); ssa_v[si]=v; emit(ctx, "; invoke"); emit(ctx, "$v = 0"))
        end
        # Emit terminator with phi args
        if haskey(bb_term, bi)
            term = bb_term[bi]
            if term[1] == :goto
                tbb = term[2]
                args = String[]
                # Iterate phis in statement order (sorted by stmt index)
                for psi in sort(collect(keys(phi_val)))
                    pbi = 0
                    for (b, blk) in enumerate(cfg.blocks)
                        psi in blk.stmts && (pbi = b; break)
                    end
                    pbi != tbb && continue
                    pn = ir.stmts[psi][:stmt]
                    pn isa Core.PhiNode || continue
                    vi = findfirst(==(Int32(bi)), pn.edges)
                    vi !== nothing && push!(args, _resolve(ssa_v, arg_v, pn.values[vi]))
                end
                # Materialize constant args as SSA values
                ssa_args = String[]
                for a in args
                    if occursin(r"^-?\d+$", a) || occursin(r"^0x[0-9a-fA-F]+$", a)
                        v = freshv(ctx); emit(ctx, "$v = iconst.i64 $a")
                        push!(ssa_args, v)
                    else
                        push!(ssa_args, a)
                    end
                end
                asuffix = isempty(ssa_args) ? "" : "($(join(ssa_args, ", ")))"
                emit(ctx, "jump $(bb_name[tbb])$asuffix")
            elseif term[1] == :gotoifnot
                cond, dbb = term[2], term[3]; fbb = bi + 1
                # Try to trace through not_int to use raw icmp directly
                use_cond = cond
                swap_targets = false
                if cond isa Core.SSAValue && haskey(ssa_v, cond.id)
                    # Check if the cond SSA was produced by not_int
                    cs = ir.stmts[cond.id][:stmt]
                    if cs isa Expr && cs.head == :call
                        csf = cs.args[1]
                        if csf isa Core.GlobalRef && csf.name == :not_int
                            # Trace to the input of not_int
                            inner = cs.args[2]
                            if inner isa Core.SSAValue
                                use_cond = inner
                                swap_targets = true  # swap because we removed NOT
                            end
                        end
                    end
                end
                s_cond = _resolve(ssa_v, arg_v, use_cond)
                t1, t2 = swap_targets ? (dbb, fbb) : (fbb, dbb)
                function phi_args(tgt)
                    a = String[]
                    for psi in sort(collect(keys(phi_val)))
                        pbi = 0
                        for (b, blk) in enumerate(cfg.blocks)
                            psi in blk.stmts && (pbi = b; break)
                        end
                        pbi != tgt && continue
                        pn = ir.stmts[psi][:stmt]
                        pn isa Core.PhiNode || continue
                        vi = findfirst(==(Int32(bi)), pn.edges)
                        vi !== nothing && push!(a, _resolve(ssa_v, arg_v, pn.values[vi]))
                    end
                    ssa_a = String[]
                    for arg in a
                        if occursin(r"^-?\d+$", arg) || occursin(r"^0x[0-9a-fA-F]+$", arg)
                            v = freshv(ctx); emit(ctx, "$v = iconst.i64 $arg"); push!(ssa_a, v)
                        else
                            push!(ssa_a, arg)
                        end
                    end
                    return isempty(ssa_a) ? "" : "($(join(ssa_a, ", ")))"
                end
                emit(ctx, "brif $s_cond, $(bb_name[t1])$(phi_args(t1)), $(bb_name[t2])$(phi_args(t2))")
            elseif term[1] == :return
                emit(ctx, "return $(_resolve(ssa_v, arg_v, term[2]))")
            end
        elseif bi < nbb
            # Unterminated block: fall through with phi args
            tbb = bi + 1
            args = String[]
            for psi in sort(collect(keys(phi_val)))
                pbi = 0
                for (b, blk) in enumerate(cfg.blocks)
                    psi in blk.stmts && (pbi = b; break)
                end
                pbi != tbb && continue
                pn = ir.stmts[psi][:stmt]
                pn isa Core.PhiNode || continue
                vi = findfirst(==(Int32(bi)), pn.edges)
                vi !== nothing && push!(args, _resolve(ssa_v, arg_v, pn.values[vi]))
            end
            ssa_args = String[]
            for a in args
                if occursin(r"^-?\d+$", a) || occursin(r"^0x[0-9a-fA-F]+$", a)
                    v = freshv(ctx); emit(ctx, "$v = iconst.i64 $a"); push!(ssa_args, v)
                else
                    push!(ssa_args, a)
                end
            end
            asuffix = isempty(ssa_args) ? "" : "($(join(ssa_args, ", ")))"
            emit(ctx, "jump $(bb_name[tbb])$asuffix")
        end
    end
    ctx.indent -= 2; emit_raw(ctx, "}\n"); String(take!(ctx.io))
end

function compile_to_clif(interp::WasmInterp, f, argtypes::Type{<:Tuple}; entry_name::String="entry")
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    matches === nothing && error("no method found for $f")
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    length(result) == 1 || throw(CompileError("expected unique match"))
    ir, rettype = result[1]
    tlist = Type[mi.specTypes.parameters...]; length(tlist) > 0 && (tlist = tlist[2:end])
    return emit_clif_function(ir, tlist, rettype, entry_name)
end
