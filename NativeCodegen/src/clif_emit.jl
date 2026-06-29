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
        # For comparisons, don't extend - keep as i8 for brif compatibility
        emit(ctx, "$result = $op $ca, $cb")
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

    emit_raw(ctx, "block0($(join(["$(n): $(t)" for (n,t) in bb_params[1]], ", "))):\n")
    ctx.indent += 1

    # Terminators
    bb_term = Dict{Int,Tuple}()
    for (bi, block) in enumerate(cfg.blocks)
        lst = ir.stmts[last(block.stmts)][:stmt]
        lst isa Core.GotoNode && (bb_term[bi] = (:goto, lst.label))
        lst isa Core.GotoIfNot && (bb_term[bi] = (:gotoifnot, lst.cond, lst.dest))
        if lst isa Core.ReturnNode
            # Handle both ReturnNode with and without value
            val = try lst.val; catch; nothing end
            bb_term[bi] = (:return, val)
        end
    end

    ssa_v = Dict{Int,String}()

    for (bi, block) in enumerate(cfg.blocks)
        if bi > 1
            # Emit block headers with zero indentation (same as block0)
            ctx.indent -= 1
            if isempty(bb_params[bi])
                emit_raw(ctx, "$(bb_name[bi]):\n")
            else
                emit_raw(ctx, "$(bb_name[bi])($(join(["$(n): $(t)" for (n,t) in bb_params[bi]], ", "))):\n")
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

                    # Handle String field access (simplified String model)
                    if T === String
                        # In our simplified String model, String pointers point to data directly
                        # The GC header is at -HEADER_SIZE offset
                        # String layout: {data*, length, flags} where:
                        # - "data" is actually the pointer we have (so, points to character data)
                        # - "length" is stored in GC header at -4 offset (so - 4)
                        # - "flags" would be at -8 offset (so - 8)

                        if fn == :data || fn == :payload
                            # For String, "data" field is the pointer we already have
                            emit(ctx, "$v = $so")
                        elseif fn == :length
                            # Load length from GC header (offset -4 from data pointer)
                            v_offset = freshv(ctx); emit(ctx, "$v_offset = iconst.i64 -4")
                            v_header_ptr = freshv(ctx); emit(ctx, "$v_header_ptr = iadd $so, $v_offset")
                            v_len32 = freshv(ctx); emit(ctx, "$v_len32 = load.i32 $v_header_ptr")
                            emit(ctx, "$v = uextend.i64 $v_len32")
                        elseif fn == :flags || fn == :flag
                            # Load flags from GC header (offset -8 from data pointer)
                            v_offset = freshv(ctx); emit(ctx, "$v_offset = iconst.i64 -8")
                            v_header_ptr = freshv(ctx); emit(ctx, "$v_header_ptr = iadd $so, $v_offset")
                            v_flags32 = freshv(ctx); emit(ctx, "$v_flags32 = load.i32 $v_header_ptr")
                            emit(ctx, "$v = uextend.i64 $v_flags32")
                        else
                            emit(ctx, "; getfield unknown String field $fn")
                            emit(ctx, "$v = 0")
                        end
                        continue
                    end

                    # Original mutable struct handling
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

                    # Handle String field setting (simplified String model)
                    if T === String
                        if fn == :length
                            # Store length to GC header (offset -4 from data pointer)
                            v_offset = freshv(ctx); emit(ctx, "$v_offset = iconst.i64 -4")
                            v_header_ptr = freshv(ctx); emit(ctx, "$v_header_ptr = iadd $so, $v_offset")
                            emit(ctx, "store.i32 $sv, $v_header_ptr")
                            ssa_v[si] = so  # setfield! returns the modified object
                        elseif fn == :flags || fn == :flag
                            # Store flags to GC header (offset -8 from data pointer)
                            v_offset = freshv(ctx); emit(ctx, "$v_offset = iconst.i64 -8")
                            v_header_ptr = freshv(ctx); emit(ctx, "$v_header_ptr = iadd $so, $v_offset")
                            emit(ctx, "store.i32 $sv, $v_header_ptr")
                            ssa_v[si] = so  # setfield! returns the modified object
                        else
                            emit(ctx, "; setfield! unknown String field $fn")
                            emit(ctx, "$v = 0")
                        end
                        continue
                    end

                    # Original mutable struct handling
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
                f isa Core.GlobalRef && name === nothing && (name = f.name)  # Handle other GlobalRef functions
                # Handle built-in functions like sizeof that appear literally
                name === nothing && f === sizeof && (name = :sizeof)
                name === nothing && f === Core.sizeof && (name = :sizeof)

                # Handle string-specific intrinsics
                if name == :sizeof || name == :sizeof_unaligned
                    # Check if this is sizeof(String)
                    obj = e.args[2]
                    obj_type = nothing
                    if obj isa Core.Argument
                        obj_idx = obj.n - 2 + 1
                        if obj_idx >= 1 && obj_idx <= length(argtypes)
                            obj_type = argtypes[obj_idx]
                        end
                    end

                    if obj_type === String
                        # For String, sizeof should load the length from Julia's String layout
                        # Based on debug output, the length is at offset 0 for the string data pointer
                        so = _resolve(ssa_v, arg_v, obj)

                        # Load the length directly from offset 0 (as seen in debug)
                        # Load the length (i32) and extend to i64
                        v_len32 = freshv(ctx)
                        emit(ctx, "$v_len32 = load.i32 $so")
                        emit(ctx, "$v = uextend.i64 $v_len32")

                        ssa_v[si] = v
                        continue
                    end
                end

                name === nothing && (emit(ctx, "; call $f"); emit(ctx, "$v = 0"); continue)
                a1 = length(e.args)>=2 ? e.args[2] : nothing
                a2 = length(e.args)>=3 ? e.args[3] : nothing

                # String operations (Phase 2)
                if name == :getindex && length(e.args) >= 3
                    obj, idx = e.args[2], e.args[3]
                    so = _resolve(ssa_v, arg_v, obj)
                    si = _resolve(ssa_v, arg_v, idx)

                    # Check if this is a string index operation
                    obj_type = nothing
                    if obj isa Core.Argument
                        obj_idx = obj.n - 2 + 1
                        if obj_idx >= 1 && obj_idx <= length(argtypes)
                            obj_type = argtypes[obj_idx]
                        end
                    end

                    if obj_type === String
                        # Call __jl_string_get
                        emit(ctx, "call __jl_string_get, $v, $so, $si")
                        ssa_v[si] = v
                        continue
                    end

                    # Array operations (Phase 3)
                    if obj_type isa DataType && obj_type.name === Array
                        # For arrays, emit load operation
                        # TODO: handle different element types
                        emit(ctx, "$v = load.i64 $so")  # simplified for now
                        ssa_v[si] = v
                        continue
                    end
                end

                if name == :setindex! && length(e.args) >= 4
                    obj, idx, val = e.args[2], e.args[3], e.args[4]
                    so = _resolve(ssa_v, arg_v, obj)
                    si = _resolve(ssa_v, arg_v, idx)
                    sv = _resolve(ssa_v, arg_v, val)

                    # Check if this is a string setindex operation
                    obj_type = nothing
                    if obj isa Core.Argument
                        obj_idx = obj.n - 2 + 1
                        if obj_idx >= 1 && obj_idx <= length(argtypes)
                            obj_type = argtypes[obj_idx]
                        end
                    end

                    if obj_type === String
                        # Call __jl_string_set
                        emit(ctx, "call __jl_string_set, $so, $si, $sv")
                        ssa_v[si] = so
                        continue
                    end

                    # Array operations (Phase 3)
                    if obj_type isa DataType && obj_type.name === Array
                        # For arrays, emit store operation
                        emit(ctx, "store.i64 $sv, $so")  # simplified for now
                        ssa_v[si] = so
                        continue
                    end
                end

                clif_intrinsic(ctx, v, name,
                    a1 !== nothing ? _resolve(ssa_v, arg_v, a1) : "",
                    a2 !== nothing ? _resolve(ssa_v, arg_v, a2) : "")
                continue
            end
            e isa Expr && e.head == :invoke &&
                let invoke_func = e.args[1]
                    # Define v for invoke expressions (similar to call expressions)
                    v = freshv(ctx); ssa_v[si] = v

                    # The invoke expression structure is:
                    # args[1]: CodeInstance (function being called)
                    # args[2]: GlobalRef (function reference like Base.ncodeunits)
                    # args[3:]: actual arguments to the function
                    invoke_args_all = e.args[2:end]
                    # Skip the first element (the GlobalRef function reference)
                    invoke_args = length(invoke_args_all) >= 2 ? invoke_args_all[2:end] : []

                    # Check if this is length(String) - we can handle this specially
                    is_length_string = false
                    # Check if this calls length function
                    # invoke_func can be CodeInstance or GlobalRef
                    func_name = nothing
                    if invoke_func isa Core.GlobalRef
                        func_name = invoke_func.name
                    elseif invoke_func isa Core.CodeInstance
                        # Try to extract the function name from CodeInstance
                        mi_def = invoke_func.def.def
                        if mi_def isa Function
                            func_name = mi_def.name
                        elseif mi_def isa Method
                            func_name = mi_def.name
                        end
                    end

                    # Check if this is string equality (_str_egal)
                    is_string_eq = false
                    if func_name == :_str_egal || (func_name !== nothing && string(func_name) == "==")
                        # Check if we have String arguments
                        if length(invoke_args) >= 2
                            arg1 = invoke_args[1]
                            arg2 = invoke_args[2]
                            if arg1 isa Core.Argument && arg2 isa Core.Argument
                                arg1_idx = arg1.n - 2 + 1
                                arg2_idx = arg2.n - 2 + 1
                                if arg1_idx >= 1 && arg1_idx <= length(argtypes) && arg2_idx >= 1 && arg2_idx <= length(argtypes)
                                    arg1_type = argtypes[arg1_idx]
                                    arg2_type = argtypes[arg2_idx]
                                    is_string_eq = (arg1_type === String && arg2_type === String)
                                end
                            end
                        end
                    end

                    # Check if this is ncodeunits (used by isempty)
                    is_ncodeunits = false
                    if func_name == :ncodeunits
                        if length(invoke_args) >= 1
                            arg = invoke_args[1]
                            if arg isa Core.Argument
                                arg_idx = arg.n - 2 + 1
                                if arg_idx >= 1 && arg_idx <= length(argtypes)
                                    arg_type = argtypes[arg_idx]
                                    is_ncodeunits = (arg_type === String)
                                end
                            end
                        end
                    end

                    # Check if this is codeunit (get character from string)
                    is_codeunit = false
                    if func_name == :codeunit
                        if length(invoke_args) >= 2
                            str_arg = invoke_args[1]
                            idx_arg = invoke_args[2]
                            if str_arg isa Core.Argument && idx_arg isa Core.Argument
                                str_idx = str_arg.n - 2 + 1
                                if str_idx >= 1 && str_idx <= length(argtypes)
                                    str_type = argtypes[str_idx]
                                    is_codeunit = (str_type === String)
                                end
                            end
                        end
                    end

                    # Check if this is lastindex
                    is_lastindex = false
                    if func_name == :lastindex
                        if length(invoke_args) >= 1
                            arg = invoke_args[1]
                            if arg isa Core.Argument
                                arg_idx = arg.n - 2 + 1
                                if arg_idx >= 1 && arg_idx <= length(argtypes)
                                    arg_type = argtypes[arg_idx]
                                    is_lastindex = (arg_type === String)
                                end
                            end
                        end
                    end

                    if func_name == :length
                        # Check if we have a String argument
                        if length(invoke_args) >= 1
                            arg = invoke_args[1]  # Second arg is the actual data
                            if arg isa Core.Argument
                                arg_idx = arg.n - 2 + 1
                                if arg_idx >= 1 && arg_idx <= length(argtypes)
                                    arg_type = argtypes[arg_idx]
                                    is_length_string = (arg_type === String)
                                end
                            end
                        end
                    end

                    if is_string_eq
                        # String equality: compare both length and content
                        obj1 = invoke_args[1]
                        obj2 = invoke_args[2]
                        s1 = _resolve(ssa_v, arg_v, obj1)
                        s2 = _resolve(ssa_v, arg_v, obj2)

                        # Simple implementation: compare pointers first
                        v_cmp_ptr = freshv(ctx)
                        emit(ctx, "$v_cmp_ptr = icmp eq $s1, $s2")

                        # Load lengths for both strings
                        v_len1_offset = freshv(ctx); emit(ctx, "$v_len1_offset = iconst.i64 -4")
                        v_len1_ptr = freshv(ctx); emit(ctx, "$v_len1_ptr = iadd $s1, $v_len1_offset")
                        v_len1 = freshv(ctx); emit(ctx, "$v_len1 = load.i32 $v_len1_ptr")

                        v_len2_offset = freshv(ctx); emit(ctx, "$v_len2_offset = iconst.i64 -4")
                        v_len2_ptr = freshv(ctx); emit(ctx, "$v_len2_ptr = iadd $s2, $v_len2_offset")
                        v_len2 = freshv(ctx); emit(ctx, "$v_len2 = load.i32 $v_len2_ptr")

                        # Compare lengths
                        v_cmp_len = freshv(ctx)
                        emit(ctx, "$v_cmp_len = icmp eq $v_len1, $v_len2")

                        # Combine comparisons: both must be equal for strings to be equal
                        v_and = freshv(ctx)
                        emit(ctx, "$v_and = band $v_cmp_ptr, $v_cmp_len")

                        # For simplicity, we'll just use pointer comparison for now
                        # A proper implementation would also compare content byte-by-byte
                        emit(ctx, "$v = $v_and")

                        ssa_v[si] = v
                        continue
                    end

                    if is_ncodeunits
                        # ncodeunits(String) = sizeof(String) for our purposes
                        obj = invoke_args[1]
                        so = _resolve(ssa_v, arg_v, obj)

                        # Use the same logic as sizeof(String)
                        v_len32 = freshv(ctx)
                        emit(ctx, "$v_len32 = load.i32 $so")
                        emit(ctx, "$v = uextend.i64 $v_len32")

                        ssa_v[si] = v
                        continue
                    end

                    if is_codeunit
                        # codeunit(String, index) - simplified approach for now
                        # TODO: Implement proper string data access or runtime call
                        # For now, return a placeholder to keep compilation working
                        str_obj = invoke_args[1]
                        idx_obj = invoke_args[2]
                        # s = _resolve(ssa_v, arg_v, str_obj)
                        idx = _resolve(ssa_v, arg_v, idx_obj)

                        # Placeholder: return index value cast to i32 (just for testing)
                        emit(ctx, "$v = ireduce.i32 $idx")
                        ssa_v[si] = v
                        continue

                        ssa_v[si] = v
                        continue
                    end

                    if is_lastindex
                        # lastindex(String) = ncodeunits(String) (same as length for strings)
                        obj = invoke_args[1]
                        so = _resolve(ssa_v, arg_v, obj)

                        # Load length - this is the correct lastindex for strings
                        v_len32 = freshv(ctx)
                        emit(ctx, "$v_len32 = load.i32 $so")
                        emit(ctx, "$v = uextend.i64 $v_len32")

                        ssa_v[si] = v
                        continue
                    end

                    if is_length_string
                        # length(String) = sizeof(String) for our purposes
                        obj = invoke_args[1]
                        so = _resolve(ssa_v, arg_v, obj)

                        # Use the same logic as sizeof(String)
                        v_len32 = freshv(ctx)
                        emit(ctx, "$v_len32 = load.i32 $so")
                        emit(ctx, "$v = uextend.i64 $v_len32")

                        ssa_v[si] = v
                        continue
                    end

                    # Default: unsupported invoke
                    (v=freshv(ctx); ssa_v[si]=v; emit(ctx, "; invoke - unsupported $(invoke_func)"); emit(ctx, "$v = 0"))
                end
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
                ret_val = _resolve(ssa_v, arg_v, term[2])
                # Check if we need to extend boolean i8 to i32 for function return
                if rettype === Bool
                    # For Bool returns, ensure the value is extended to i32
                    # Check if this is a raw SSA value that might be i8
                    if term[2] isa Core.SSAValue
                        si = term[2].id
                        if haskey(ssa_v, si)
                            # Create an extended version
                            v_ext = freshv(ctx)
                            emit(ctx, "$v_ext = uextend.i32 $ret_val")
                            emit(ctx, "return $v_ext")
                        else
                            emit(ctx, "return $ret_val")
                        end
                    else
                        emit(ctx, "return $ret_val")
                    end
                else
                    emit(ctx, "return $ret_val")
                end
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
