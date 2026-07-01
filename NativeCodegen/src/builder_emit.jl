# eDSL builder emitter for Julia IRCode → Cranelift IR via Rust FFI
# Direct Cranelift emission: each FFI call immediately emits one instruction.

using WasmCodegen: ScalarRepr, scalar_repr, isghost, wasm_valtype

# === Type enums (must match Rust builder.rs) ===
const TYPE_I32 = UInt32(0)
const TYPE_I64 = UInt32(1)
const TYPE_F32 = UInt32(2)
const TYPE_F64 = UInt32(3)
const TYPE_PTR = UInt32(4)
const TYPE_I8  = UInt32(5)

# === IntCC condition enums ===
const ICMP_EQ  = UInt32(0)
const ICMP_NE  = UInt32(1)
const ICMP_SLT = UInt32(2)
const ICMP_SGE = UInt32(3)
const ICMP_SGT = UInt32(4)
const ICMP_SLE = UInt32(5)
const ICMP_ULT = UInt32(6)
const ICMP_UGE = UInt32(7)
const ICMP_UGT = UInt32(8)
const ICMP_ULE = UInt32(9)

# === FloatCC condition enums ===
const FCMP_EQ = UInt32(0)
const FCMP_NE = UInt32(1)
const FCMP_LT = UInt32(2)
const FCMP_LE = UInt32(3)
const FCMP_GT = UInt32(4)
const FCMP_GE = UInt32(5)

# Julia type → Cranelift type enum
const CRANELIFT_TYPE_MAP = IdDict{Any,UInt32}(
    Int64=>TYPE_I64, UInt64=>TYPE_I64, Int32=>TYPE_I32, UInt32=>TYPE_I32,
    Int16=>TYPE_I32, UInt16=>TYPE_I32, Int8=>TYPE_I32, UInt8=>TYPE_I32,
    Bool=>TYPE_I32, Char=>TYPE_I32, Float64=>TYPE_F64, Float32=>TYPE_F32,
)

function cranelift_type(T)
    t = get(CRANELIFT_TYPE_MAP, T, nothing)
    t !== nothing && return t
    T isa DataType && Base.ismutabletype(T) && !(T <: Ptr) && return TYPE_PTR
    # Handle tuples as pointer types (multi-element tuples need memory allocation)
    T isa DataType && T <: Tuple && return TYPE_PTR
    # Immutable non-bitstype structs with heap fields (e.g. GreenNode, Wrapper)
    # are also pointers. Exclude MemoryRef/Memory (need Case 2 ref_tracking).
    _is_heap_struct(T) && return TYPE_PTR
    r = scalar_repr(T)
    if r !== nothing
        return r.vt == WasmCodegen.I64 ? TYPE_I64 : r.vt == WasmCodegen.I32 ? TYPE_I32 :
               r.vt == WasmCodegen.F64 ? TYPE_F64 : TYPE_F32
    end
    # Bitstypes: map to Cranelift type by sizeof
    if T isa DataType && isbitstype(T)
        sz = sizeof(T)
        sz == 8 && return TYPE_I64
        sz == 4 && return TYPE_I32
        sz == 1 && return TYPE_I8
    end
    # Abstract types that are always heap pointers (e.g. AbstractString, Exception)
    isabstracttype(T) && return TYPE_PTR
    throw(CompileError("unsupported type $T"))
end

# Predicate: concrete immutable struct with heap fields that should be pointer-typed.
# Excludes GenericMemoryRef/GenericMemory (Core memory types managed via ref_tracking).
_is_heap_struct(T) = T isa DataType && isconcretetype(T) && !isbitstype(T) &&
                     !(T.name.name in (:GenericMemoryRef, :GenericMemory)) && !(T <: Ptr)

function is_ptr_type(T)
    T isa DataType && !(T <: Ptr) && (
        Base.ismutabletype(T) || T === String || T <: Tuple || _is_heap_struct(T)
    )
end

# === BuilderCtx: tracks a Rust FunctionCtx for one Julia function ===

mutable struct BuilderCtx
    builder_handle::Ptr{Cvoid}  # *mut BuilderContext (Rust side)
    fctx_handle::Ptr{Cvoid}     # *mut FunctionCtx (Rust side, current function)
    lib_handle::Ptr{Cvoid}      # dlopen handle for native-builder library
    # SSA value tracking
    ssa_values::Dict{Core.SSAValue, UInt32}
    arg_values::Dict{Core.Argument, UInt32}
    blocks::Dict{Int, String}   # Julia block index → Cranelift block name
    # Composed offset tracking: SSA value → (base_ptr_id, composed_offset, struct_type)
    # Used when getfield loads a non-loadable type like MemoryRef — subsequent
    # getfield on that SSA value recomposes the full offset from the base pointer.
    ref_tracking::Dict{Core.SSAValue, Tuple{UInt32, Int, DataType}}
    # checked-arithmetic pairs: stmt_idx → (value_id, flag_id). A single
    # checked_{s,u}{add,sub,mul}_int IR stmt materializes TWO value ids (the
    # unchecked result + the overflow flag); getfield(pair, 1/2) reads them.
    # Mirrors WasmCodegen's `ssapair` mechanism (compiler.jl).
    ssa_pairs::Dict{Int, Tuple{UInt32, UInt32}}
end

function BuilderCtx(lib_path::String)
    lib = Libdl.dlopen(lib_path)
    create_ptr = Libdl.dlsym(lib, :create_builder)
    ctx = ccall(create_ptr, Ptr{Cvoid}, ())
    BuilderCtx(ctx, C_NULL, lib,
               Dict{Core.SSAValue, UInt32}(),
               Dict{Core.Argument, UInt32}(),
               Dict{Int, String}(),
               Dict{Core.SSAValue, Tuple{UInt32, Int, DataType}}(),
               Dict{Int, Tuple{UInt32, UInt32}}())
end

function free_builder(bc::BuilderCtx)
    if bc.builder_handle != C_NULL
        free_ptr = Libdl.dlsym(bc.lib_handle, :free_builder)
        ccall(free_ptr, Cvoid, (Ptr{Cvoid},), bc.builder_handle)
    end
    if bc.lib_handle != C_NULL
        Libdl.dlclose(bc.lib_handle)
    end
end

# === Main entry point ===

function emit_function_via_builder(interp::WasmInterp, f, argtypes::Type{<:Tuple};
                                   name::String="entry", output_path::String=tempname()*".o")
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    matches === nothing && error("no method found for $f")
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    length(result) == 1 || throw(CompileError("expected unique match"))
    ir, rettype = result[1]

    builder_lib = get_native_builder_lib()
    bc = BuilderCtx(builder_lib)

    try
        # Declare runtime imports (GC allocation, string ops, etc.)
        _declare_imports(bc)

        # Register argument values: Julia Argument(1)=function, Argument(2)=first param, ...
        # Map to 0-based: Argument(2) → 0, Argument(3) → 1, etc.
        nparams = length(mi.specTypes.parameters) - 1  # first is Tuple type
        for i in 1:nparams
            bc.arg_values[Core.Argument(i + 1)] = UInt32(i - 1)  # first param → 0
        end
        # Also map Argument(1) to a sentinel (shouldn't be referenced but just in case)
        bc.arg_values[Core.Argument(1)] = UInt32(0)

        # Add function to builder
        ret_type_enum = cranelift_type(rettype)
        param_type_enums = UInt32[cranelift_type(t) for t in mi.specTypes.parameters[2:end]]

        add_func_ptr = Libdl.dlsym(bc.lib_handle, :builder_add_function)
        bc.fctx_handle = ccall(add_func_ptr, Ptr{Cvoid},
                                (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                                bc.builder_handle, name, ret_type_enum,
                                param_type_enums, length(param_type_enums))

        bc.fctx_handle == C_NULL && error("Failed to add function")

        # Pre-create Cranelift blocks for each Julia basic block
        # Skip block 1 (→ block0) — already created by Rust FunctionCtx::new()
        cfg = ir.cfg
        for bi in 1:length(cfg.blocks)
            block_name = "block$(bi-1)"  # Julia 1-based → Rust 0-based
            bc.blocks[bi] = block_name
            if bi == 1
                # Entry block already exists with function params
                continue
            end
            add_block_ptr = Libdl.dlsym(bc.lib_handle, :function_add_block)
            ccall(add_block_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)
        end

        # Pre-scan for phi nodes: create Cranelift block params
        add_bp = Libdl.dlsym(bc.lib_handle, :function_add_block_param)
        for (bi, block) in enumerate(cfg.blocks)
            block_name = bc.blocks[bi]
            for si in block.stmts
                e = ir.stmts[si][:stmt]
                if e isa Core.PhiNode
                    phi_type_enum = cranelift_type(ir.stmts[si][:type])
                    param_id = ccall(add_bp, UInt32, (Ptr{Cvoid}, Ptr{UInt8}, UInt32),
                                    bc.fctx_handle, block_name, phi_type_enum)
                    bc.ssa_values[Core.SSAValue(si)] = param_id
                end
            end
        end

        # Process each block
        for (bi, block) in enumerate(cfg.blocks)
            block_name = bc.blocks[bi]
            # Switch to this block
            switch_ptr = Libdl.dlsym(bc.lib_handle, :function_switch_block)
            ccall(switch_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)

            # Process statements
            had_terminator = false
            for si in block.stmts
                had_terminator && break
                e = ir.stmts[si][:stmt]
                emit_instruction(bc, e, ir, si)
                if e isa Core.GotoNode || e isa Core.GotoIfNot || e isa Core.ReturnNode
                    had_terminator = true
                elseif e isa Expr && e.head == :call && length(e.args) >= 1
                    f = e.args[1]
                    if f isa Core.GlobalRef && f.name == :throw
                        had_terminator = true
                    end
                end
            end

            # Implicit jump: block has successors but no explicit terminator
            if !had_terminator && length(block.succs) == 1
                target_bi = block.succs[1]
                target_name = bc.blocks[target_bi]
                phi_args = get_phi_args(ir, bc, bi, target_bi)
                if isempty(phi_args)
                    jump_ptr = Libdl.dlsym(bc.lib_handle, :block_add_jump)
                    ccall(jump_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}), bc.fctx_handle, target_name)
                else
                    jump_ptr = Libdl.dlsym(bc.lib_handle, :block_add_jump_args)
                    ccall(jump_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt32}, Csize_t),
                          bc.fctx_handle, target_name, phi_args, length(phi_args))
                end
            end

            # Seal the block
            seal_ptr = Libdl.dlsym(bc.lib_handle, :function_seal_block)
            ccall(seal_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)
        end

        # Finalize to object file
        finalize_ptr = Libdl.dlsym(bc.lib_handle, :builder_finalize)
        status = ccall(finalize_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}),
                       bc.builder_handle, output_path)
        status != 0 && error("Builder finalization failed")

        return output_path
    finally
        free_builder(bc)
    end
end

# === Emit a single IR instruction ===

function emit_instruction(bc::BuilderCtx, e, ir, stmt_idx::Int)
    if e isa Expr && e.head == :call
        f = e.args[1]
        args = e.args[2:end]
        if f isa Core.IntrinsicFunction
            result_id = emit_intrinsic(bc, f, args, ir, stmt_idx)
        elseif f isa Core.GlobalRef
            result_id = emit_globalref(bc, f, args, ir, stmt_idx)
        elseif f === Core.sizeof || f === sizeof
            # sizeof(s::String) == ncodeunits(s) — emit load from ptr+0
            result_id = emit_string_ncodeunits(bc, args, ir)
        elseif f === Core.memoryrefunset!
            # memoryrefunset!(ref, ordering, boundscheck) — store zero at ref for GC safety
            result_id = emit_memoryrefunset(bc, args, ir)
        elseif f === Core.isa
            # isa(x, Type) — type check. Currently only handles isa(x, Nothing)
            # on pointer values (icmp eq ptr_val, 0).
            result_id = emit_isa(bc, args, ir)
        else
            error("Unsupported call: $(f)")
        end
        if result_id !== nothing
            bc.ssa_values[Core.SSAValue(stmt_idx)] = result_id
        end
    elseif e isa Expr && e.head == :invoke
        mi = e.args[1]  # MethodInstance or CodeInstance
        f = e.args[2]   # Function being called
        invoke_args = e.args[3:end]  # Call arguments
        result_id = emit_invoke(bc, mi, f, invoke_args, ir, stmt_idx)
        if result_id !== nothing
            bc.ssa_values[Core.SSAValue(stmt_idx)] = result_id
        end
    elseif e isa Expr && e.head == :new
        # %new(T, fields...) — construct a new struct (mutable or immutable)
        T = e.args[1]
        field_args = e.args[2:end]
        result_id = emit_new(bc, T, field_args, ir, stmt_idx)
        if result_id !== nothing
            bc.ssa_values[Core.SSAValue(stmt_idx)] = result_id
        end
    elseif e isa Core.ReturnNode
        val = try e.val; catch; nothing end
        if val !== nothing
            value_id = resolve_operand(bc, val, ir)
            return_ptr = Libdl.dlsym(bc.lib_handle, :block_add_return)
            ccall(return_ptr, Cvoid, (Ptr{Cvoid}, UInt32), bc.fctx_handle, value_id)
        else
            # Check if this is unreachable (return type is Union{})
            stmt_type = ir.stmts[stmt_idx][:type]
            if stmt_type == Union{}
                trap_ptr = Libdl.dlsym(bc.lib_handle, :block_add_trap)
                ccall(trap_ptr, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
            else
                return_ptr = Libdl.dlsym(bc.lib_handle, :block_add_return_void)
                ccall(return_ptr, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
            end
        end
    elseif e isa Core.GotoNode
        target_bi = e.label
        target_name = bc.blocks[target_bi]
        current_bi = find_block_for_stmt(ir, stmt_idx)
        phi_args = current_bi !== nothing ? get_phi_args(ir, bc, current_bi, target_bi) : UInt32[]
        if isempty(phi_args)
            jump_ptr = Libdl.dlsym(bc.lib_handle, :block_add_jump)
            ccall(jump_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}), bc.fctx_handle, target_name)
        else
            jump_ptr = Libdl.dlsym(bc.lib_handle, :block_add_jump_args)
            ccall(jump_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt32}, Csize_t),
                  bc.fctx_handle, target_name, phi_args, length(phi_args))
        end
    elseif e isa Expr && e.head == :boundscheck
        # boundscheck true/false — emit as Bool constant
        flag = length(e.args) >= 1 ? e.args[1] : true
        val = flag == true ? Int64(1) : Int64(0)
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        result_id = ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                          bc.fctx_handle, val, TYPE_I32)
        bc.ssa_values[Core.SSAValue(stmt_idx)] = result_id
    elseif e isa Core.PiNode
        # PiNode is a type assertion — pass the value through unchanged.
        # Track the input value under the PiNode's SSA slot.
        input_val = e.val
        if input_val !== nothing
            input_id = resolve_operand(bc, input_val, ir)
            bc.ssa_values[Core.SSAValue(stmt_idx)] = input_id
        end
    elseif e isa Core.GotoIfNot
        cond_id = resolve_operand(bc, e.cond, ir)
        dest_bi = e.dest
        dest_name = bc.blocks[dest_bi]
        current_bi = find_block_for_stmt(ir, stmt_idx)
        fallthrough_bi = nothing
        if current_bi !== nothing && length(ir.cfg.blocks[current_bi].succs) >= 2
            succs = ir.cfg.blocks[current_bi].succs
            fallthrough_bi = succs[2]
        end
        if fallthrough_bi === nothing
            fallthrough_name = dest_name
            fallthrough_phi = UInt32[]
        else
            fallthrough_name = bc.blocks[fallthrough_bi]
            fallthrough_phi = get_phi_args(ir, bc, current_bi, fallthrough_bi)
        end
        dest_phi = current_bi !== nothing ? get_phi_args(ir, bc, current_bi, dest_bi) : UInt32[]
        if isempty(fallthrough_phi) && isempty(dest_phi)
            brif_ptr = Libdl.dlsym(bc.lib_handle, :block_add_brif)
            ccall(brif_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Ptr{UInt8}, Ptr{UInt8}),
                  bc.fctx_handle, cond_id, fallthrough_name, dest_name)
        else
            brif_ptr = Libdl.dlsym(bc.lib_handle, :block_add_brif_args)
            ccall(brif_ptr, Cvoid,
                  (Ptr{Cvoid}, UInt32, Ptr{UInt8}, Ptr{UInt32}, Csize_t, Ptr{UInt8}, Ptr{UInt32}, Csize_t),
                  bc.fctx_handle, cond_id,
                  fallthrough_name, fallthrough_phi, length(fallthrough_phi),
                  dest_name, dest_phi, length(dest_phi))
        end
    else
        # Constants or other simple values — ignore
    end
end

# Get phi value IDs to pass from source_bi to target_bi
function get_phi_args(ir, bc::BuilderCtx, source_bi::Int, target_bi::Int)
    args = UInt32[]
    target_block = ir.cfg.blocks[target_bi]
    for si in target_block.stmts
        e = ir.stmts[si][:stmt]
        if e isa Core.PhiNode
            found = false
            for (j, edge_bi) in enumerate(e.edges)
                if edge_bi == source_bi
                    push!(args, resolve_operand(bc, e.values[j], ir))
                    found = true
                    break
                end
            end
            if !found
                # This phi is undefined along this edge (its variable is not
                # defined on this predecessor path — common for loop-carried
                # values on bounds-check escape paths). Pass a zero placeholder
                # of the phi's type so the jump arg count matches the block's
                # param count. The value is never used along this path.
                push!(args, _undef_placeholder(bc, ir.stmts[si][:type]))
            end
        end
    end
    return args
end

# Zero placeholder for an undefined phi edge, matching the phi value's type so
# the jump argument count lines up with the target block's parameters.
function _undef_placeholder(bc::BuilderCtx, T)
    T = T isa Core.PartialStruct ? T.typ : (T isa Core.Const ? typeof(T.val) : T)
    ty_enum = try; cranelift_type(T); catch _; TYPE_I64; end
    if ty_enum == TYPE_F64
        fptr = Libdl.dlsym(bc.lib_handle, :block_add_f64const)
        return ccall(fptr, UInt32, (Ptr{Cvoid}, Float64), bc.fctx_handle, 0.0)
    elseif ty_enum == TYPE_F32
        fptr = Libdl.dlsym(bc.lib_handle, :block_add_f32const)
        return ccall(fptr, UInt32, (Ptr{Cvoid}, Float32), bc.fctx_handle, 0.0f0)
    else
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(0), ty_enum)
    end
end

# Find which basic block contains a given statement
function find_block_for_stmt(ir, stmt_idx::Int)
    for (bi, block) in enumerate(ir.cfg.blocks)
        if stmt_idx in block.stmts
            return bi
        end
    end
    return nothing
end

# === Resolve operands to SSA value IDs ===

function resolve_operand(bc::BuilderCtx, val, ir)
    if val isa Core.SSAValue
        haskey(bc.ssa_values, val) && return bc.ssa_values[val]
        error("SSA value $val not found in tracking")
    elseif val isa Core.Argument
        haskey(bc.arg_values, val) && return bc.arg_values[val]
        error("Argument $val not found in tracking")
    elseif val isa Core.Const
        # Extract the constant value and resolve it
        return resolve_operand(bc, val.val, ir)
    elseif val isa Core.GlobalRef
        # Module-level constant (e.g. JuliaSyntax.TRIVIA_FLAG) — fetch value at
        # compile time and emit as a Cranelift immediate.
        return emit_constant(bc, getglobal(val.mod, val.name))
    elseif isa(val, Number)
        # Create constant each time (caching causes cross-block dominance issues)
        return emit_constant(bc, val)
    elseif val === nothing || isghost(typeof(val))
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                   bc.fctx_handle, Int64(0), TYPE_I32)
    elseif val isa Bool
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                   bc.fctx_handle, Int64(val ? 1 : 0), TYPE_I32)
    elseif val isa Tuple
        # Handle tuple constants by emitting tuple creation
        args = [Core.Const(v) for v in val]
        return emit_core_tuple(bc, args, ir)
    elseif val isa AbstractString
        # String literal/constant: emit its object pointer as a constant. The
        # value is already a real Julia String; it round-trips back via
        # unsafe_pointer_to_objref on return.
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(reinterpret(UInt64, pointer_from_objref(val))),
                     TYPE_PTR)
    elseif Base.isprimitivetype(typeof(val))
        # Primitive type (e.g. JuliaSyntax.Kind is `primitive type Kind 16 end`) —
        # reinterpret to integer bits and emit as constant.
        raw = reinterpret(UInt16, val)
        return emit_constant(bc, Int32(raw))
    else
        error("Unsupported operand type: $(typeof(val))")
    end
end

function emit_constant(bc::BuilderCtx, val)
    if val isa Float64
        f64_ptr = Libdl.dlsym(bc.lib_handle, :block_add_f64const)
        return ccall(f64_ptr, UInt32, (Ptr{Cvoid}, Float64), bc.fctx_handle, Float64(val))
    elseif val isa Float32
        f32_ptr = Libdl.dlsym(bc.lib_handle, :block_add_f32const)
        return ccall(f32_ptr, UInt32, (Ptr{Cvoid}, Float32), bc.fctx_handle, Float32(val))
    elseif val isa Integer
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        ty = val isa Int64 || val isa UInt64 ? TYPE_I64 : TYPE_I32
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(val), ty)
    else
        error("Unsupported constant type: $(typeof(val))")
    end
end

# === Intrinsic emission ===

function emit_intrinsic(bc::BuilderCtx, f::Core.IntrinsicFunction, args, ir, stmt_idx)
    # checked {add,sub,mul}: return (value, overflowed::Bool) — materialized as a
    # pair of value ids (see emit_checked_pair); returns nothing so the call's
    # SSA slot is NOT recorded in ssa_values (consumed via getfield(pair, k)).
    # Identified by identity (===) because jl_intrinsic_name returns "invalid"
    # for these newer intrinsics — they're missing from that C table.
    f === Core.Intrinsics.checked_sadd_int && return emit_checked_pair(bc, :add, true,  args, ir, stmt_idx)
    f === Core.Intrinsics.checked_uadd_int && return emit_checked_pair(bc, :add, false, args, ir, stmt_idx)
    f === Core.Intrinsics.checked_ssub_int && return emit_checked_pair(bc, :sub, true,  args, ir, stmt_idx)
    f === Core.Intrinsics.checked_usub_int && return emit_checked_pair(bc, :sub, false, args, ir, stmt_idx)
    f === Core.Intrinsics.checked_smul_int && return emit_checked_pair(bc, :mul, true,  args, ir, stmt_idx)
    f === Core.Intrinsics.checked_umul_int && return emit_checked_pair(bc, :mul, false, args, ir, stmt_idx)
    # bitcast reinterprets the same bits as a different type — no-op at Cranelift level
    f === Core.Intrinsics.bitcast && return resolve_operand(bc, args[2], ir)

    # Map intrinsic to Rust FFI call
    fn_name = ccall(:jl_intrinsic_name, Ptr{UInt8}, (Any,), f)
    fn_sym = unsafe_string(fn_name) |> Symbol

    # Arithmetic
    fn_sym == :add_int && return emit_binop(bc, :block_add_iadd, args, ir)
    fn_sym == :sub_int && return emit_binop(bc, :block_add_isub, args, ir)
    fn_sym == :mul_int && return emit_binop(bc, :block_add_imul, args, ir)
    fn_sym == :sdiv_int && return emit_binop(bc, :block_add_sdiv, args, ir)
    fn_sym == :udiv_int && return emit_binop(bc, :block_add_udiv, args, ir)
    fn_sym == :srem_int && return emit_binop(bc, :block_add_srem, args, ir)
    fn_sym == :urem_int && return emit_binop(bc, :block_add_urem, args, ir)

    # Comparisons
    fn_sym == :eq_int  && return emit_icmp(bc, ICMP_EQ, args, ir)
    fn_sym == :ne_int  && return emit_icmp(bc, ICMP_NE, args, ir)
    fn_sym == :slt_int && return emit_icmp(bc, ICMP_SLT, args, ir)
    fn_sym == :sle_int && return emit_icmp(bc, ICMP_SLE, args, ir)
    fn_sym == :ult_int && return emit_icmp(bc, ICMP_ULT, args, ir)
    fn_sym == :ule_int && return emit_icmp(bc, ICMP_ULE, args, ir)

    # Bitwise
    fn_sym == :and_int && return emit_binop(bc, :block_add_band, args, ir)
    fn_sym == :or_int  && return emit_binop(bc, :block_add_bor, args, ir)
    fn_sym == :xor_int && return emit_binop(bc, :block_add_bxor, args, ir)
    fn_sym == :shl_int && return emit_binop(bc, :block_add_ishl, args, ir)
    fn_sym == :lshr_int && return emit_binop(bc, :block_add_ushr, args, ir)
    fn_sym == :ashr_int && return emit_binop(bc, :block_add_sshr, args, ir)

    # Conversions (int widening/narrowing)
    fn_sym == :zext_int && return emit_convert(bc, :block_add_uextend, args, ir)
    fn_sym == :sext_int && return emit_convert(bc, :block_add_sextend, args, ir)
    fn_sym == :trunc_int && return emit_trunc(bc, args, ir)
    # Conversions (int <-> float): (Type, value) — Type is the *result* type.
    fn_sym == :sitofp && return emit_convert(bc, :block_add_fcvt_from_sint, args, ir)
    fn_sym == :uitofp && return emit_convert(bc, :block_add_fcvt_from_uint, args, ir)
    fn_sym == :fptosi && return emit_convert(bc, :block_add_fcvt_to_sint_sat, args, ir)
    fn_sym == :fptoui && return emit_convert(bc, :block_add_fcvt_to_uint_sat, args, ir)
    fn_sym == :fpext   && return emit_convert(bc, :block_add_fpromote, args, ir)
    fn_sym == :fptrunc && return emit_convert(bc, :block_add_fdemote, args, ir)

    # Float arithmetic
    fn_sym == :add_float && return emit_binop(bc, :block_add_fadd, args, ir)
    fn_sym == :sub_float && return emit_binop(bc, :block_add_fsub, args, ir)
    fn_sym == :mul_float && return emit_binop(bc, :block_add_fmul, args, ir)
    fn_sym == :div_float && return emit_binop(bc, :block_add_fdiv, args, ir)
    fn_sym == :neg_float && return emit_unop(bc, :block_add_fneg, args, ir)
    # Float math (unops — Cranelift infers width from operand; binop for copysign)
    fn_sym == :sqrt_llvm && return emit_unop(bc, :block_add_sqrt, args, ir)
    fn_sym == :ceil_llvm && return emit_unop(bc, :block_add_ceil, args, ir)
    fn_sym == :floor_llvm && return emit_unop(bc, :block_add_floor, args, ir)
    fn_sym == :trunc_llvm && return emit_unop(bc, :block_add_trunc, args, ir)
    fn_sym == :rint_llvm && return emit_unop(bc, :block_add_nearest, args, ir)
    fn_sym == :abs_float && return emit_unop(bc, :block_add_fabs, args, ir)
    fn_sym == :copysign_float && return emit_binop(bc, :block_add_fcopysign, args, ir)

    # Float comparisons
    fn_sym == :eq_float && return emit_fcmp(bc, FCMP_EQ, args, ir)
    fn_sym == :ne_float && return emit_fcmp(bc, FCMP_NE, args, ir)
    fn_sym == :lt_float && return emit_fcmp(bc, FCMP_LT, args, ir)
    fn_sym == :le_float && return emit_fcmp(bc, FCMP_LE, args, ir)

    # neg_int = 0 - x
    fn_sym == :neg_int && return emit_neg_int(bc, args, ir)
    # not_int = x ⊻ -1
    fn_sym == :not_int && return emit_not_int(bc, args, ir)

    # Bit-count / byte-swap unops (same width in/out; Cranelift infers width)
    fn_sym == :ctlz_int && return emit_unop(bc, :block_add_clz, args, ir)
    fn_sym == :cttz_int && return emit_unop(bc, :block_add_ctz, args, ir)
    fn_sym == :ctpop_int && return emit_unop(bc, :block_add_popcnt, args, ir)
    fn_sym == :bswap_int && return emit_unop(bc, :block_add_bswap, args, ir)
    # flipsign_int(x, y) = (x ⊻ s) - s with s = y >>> (bits-1). Also covers abs
    # (the IR lowers abs(x) to flipsign_int(x, x)).
    fn_sym == :flipsign_int && return emit_flipsign_int(bc, args, ir)

    error("Unsupported intrinsic: $fn_sym")
end

# === FFI helpers ===

function emit_binop(bc::BuilderCtx, ffi_sym::Symbol, args, ir)
    length(args) < 2 && error("Binary op needs 2 args")
    lhs = resolve_operand(bc, args[1], ir)
    rhs = resolve_operand(bc, args[2], ir)
    fn_ptr = Libdl.dlsym(bc.lib_handle, ffi_sym)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, lhs, rhs)
end

function emit_unop(bc::BuilderCtx, ffi_sym::Symbol, args, ir)
    length(args) < 1 && error("Unary op needs 1 arg")
    val = resolve_operand(bc, args[1], ir)
    fn_ptr = Libdl.dlsym(bc.lib_handle, ffi_sym)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, val)
end

function emit_icmp(bc::BuilderCtx, cond::UInt32, args, ir)
    length(args) < 2 && error("icmp needs 2 args")
    lhs = resolve_operand(bc, args[1], ir)
    rhs = resolve_operand(bc, args[2], ir)
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
    result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                   bc.fctx_handle, cond, lhs, rhs)
    # Cranelift icmp produces i8; extend to i32 for compatibility with Julia Bool
    ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
    return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, result, TYPE_I32)
end

function emit_fcmp(bc::BuilderCtx, cond::UInt32, args, ir)
    length(args) < 2 && error("fcmp needs 2 args")
    lhs = resolve_operand(bc, args[1], ir)
    rhs = resolve_operand(bc, args[2], ir)
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_fcmp)
    result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                   bc.fctx_handle, cond, lhs, rhs)
    # fcmp produces i8; extend to i32
    ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
    return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, result, TYPE_I32)
end

# Unwrap a type argument that may arrive as a bare DataType, Core.Const,
# QuoteNode, or GlobalRef to the type (e.g. GlobalRef(Base, Float64)).
_unwrap_type(T) = T isa Core.Const ? T.val :
                  T isa QuoteNode ? T.value :
                  T isa Core.GlobalRef ? getglobal(T.mod, T.name) : T

function emit_convert(bc::BuilderCtx, ffi_sym::Symbol, args, ir)
    length(args) < 2 && error("Convert needs 2 args")
    # Julia conversion intrinsics are (Type, value): e.g. sext_int(Int64, x),
    # sitofp(Float64, x), fptosi(Int64, x). args[1] is the target type.
    to_T = _unwrap_type(args[1])
    val = resolve_operand(bc, args[2], ir)
    to_type_enum = cranelift_type(to_T)
    fn_ptr = Libdl.dlsym(bc.lib_handle, ffi_sym)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, val, to_type_enum)
end

function emit_trunc(bc::BuilderCtx, args, ir)
    length(args) < 2 && error("trunc needs 2 args")
    # trunc_int(Int8, x) — args[1] is the (narrower) target type.
    to_T = _unwrap_type(args[1])
    val = resolve_operand(bc, args[2], ir)
    to_type_enum = cranelift_type(to_T)
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_ireduce)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, val, to_type_enum)
end

# neg_int: 0 - x
function emit_neg_int(bc::BuilderCtx, args, ir)
    val = resolve_operand(bc, args[1], ir)
    # Create constant 0 of same "size" — use i64 for now
    zero_id = emit_constant(bc, Int64(0))
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, zero_id, val)
end

# not_int: for Bool → logical NOT using icmp_eq(val, 0)
function emit_not_int(bc::BuilderCtx, args, ir)
    val = resolve_operand(bc, args[1], ir)
    zero = emit_constant(bc, Int32(0))
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
    result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                   bc.fctx_handle, ICMP_EQ, val, zero)
    # Like emit_icmp: Cranelift icmp returns i8; uextend to i32 for Bool.
    ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
    return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, result, TYPE_I32)
end

# flipsign_int(x, y) = y >= 0 ? x : -x, lowered as (x ⊻ s) - s with
# s = sshr(y, storage_bits-1). s is 0 when y>=0 and -1 (all ones) when y<0, so
# (x ⊻ s) - s yields x or -x respectively. The shift uses the STORAGE width
# (63 for i64, 31 for i32) — sub-word signed values are sign-extended into i32
# storage, so the sign lives at bit 31. (Lifted from WasmCodegen intrinsics.jl.)
function emit_flipsign_int(bc::BuilderCtx, args, ir)
    x = resolve_operand(bc, args[1], ir)
    y = resolve_operand(bc, args[2], ir)
    T = get_operand_type(args[1], ir)
    T = T isa Core.Const ? T.val : T
    shift = cranelift_type(T) == TYPE_I64 ? 63 : 31
    shift_id = emit_constant(bc, Int64(shift))
    # s = arithmetic-shift y by (storage_bits-1)
    sshr_ptr = Libdl.dlsym(bc.lib_handle, :block_add_sshr)
    s_id = ccall(sshr_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, y, shift_id)
    # x ⊻ s
    xor_ptr = Libdl.dlsym(bc.lib_handle, :block_add_bxor)
    xors_id = ccall(xor_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, x, s_id)
    # (x ⊻ s) - s
    sub_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    return ccall(sub_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, xors_id, s_id)
end

# --- checked-arithmetic overflow pairs (Item 5) ------------------------------
# checked_{s,u}{add,sub,mul}_int return (value, overflowed::Bool): a single IR
# stmt materialized into TWO value ids (value + flag), later read by
# getfield(pair, 1/2). We store both in bc.ssa_pairs[stmt_idx] and return
# nothing so emit_instruction does NOT record the call's SSA slot in ssa_values.
# Mirrors WasmCodegen's `ssapair` mechanism (compiler.jl). Cranelift 0.133 has
# no native overflow opcode, so overflow is detected branch-free and trap-free
# via the comparison formulation (Lifted from WasmCodegen intrinsics.jl; the
# signed-mul trap case is sidestepped with a "safe divisor" + select instead of
# if/else, since SSA select evaluates both arms — the guarded sdiv never traps).
# Only full-word widths (sizeof ∈ {4,8}) are supported; sub-word needs
# width-aware renormalization and throws CompileError (loud failure).

# value-id binop / icmp / select helpers (operands already resolved to ids)
_binop_id(bc, sym, l_id, r_id) =
    ccall(Libdl.dlsym(bc.lib_handle, sym), UInt32,
          (Ptr{Cvoid}, UInt32, UInt32), bc.fctx_handle, l_id, r_id)

function _icmp_id(bc, cond, l_id, r_id)
    r = ccall(Libdl.dlsym(bc.lib_handle, :block_add_icmp), UInt32,
              (Ptr{Cvoid}, UInt32, UInt32, UInt32), bc.fctx_handle, cond, l_id, r_id)
    # icmp yields i8; widen to i32 for Bool-domain use (matches emit_icmp).
    ccall(Libdl.dlsym(bc.lib_handle, :block_add_uextend), UInt32,
          (Ptr{Cvoid}, UInt32, UInt32), bc.fctx_handle, r, TYPE_I32)
end

_select_id(bc, cond_id, t_id, e_id) =
    ccall(Libdl.dlsym(bc.lib_handle, :block_add_select), UInt32,
          (Ptr{Cvoid}, UInt32, UInt32, UInt32), bc.fctx_handle, cond_id, t_id, e_id)

# Value element type of a checked pair: Tuple{Tvalue, Bool} from the stmt type,
# falling back to the operand's inferred type.
function _checked_value_type(ir, stmt_idx, arg1)
    TT = ir.stmts[stmt_idx][:type]
    if TT isa DataType && TT <: Tuple && length(TT.parameters) == 2
        return TT.parameters[1]
    end
    T = get_operand_type(arg1, ir)
    return T isa Core.Const ? T.val : T
end

function emit_checked_pair(bc::BuilderCtx, kind::Symbol, signed::Bool, args, ir, stmt_idx)
    a = resolve_operand(bc, args[1], ir)
    b = resolve_operand(bc, args[2], ir)
    val_T = _checked_value_type(ir, stmt_idx, args[1])
    sz = sizeof(val_T)
    (sz == 4 || sz == 8) ||
        throw(CompileError("checked arithmetic on $val_T (sub-word) not yet supported"))

    if kind === :add
        value = _binop_id(bc, :block_add_iadd, a, b)
        if signed   # overflow ⟺ ((r ⊻ a) & (r ⊻ b)) < 0  (sign of result differs from both)
            t1 = _binop_id(bc, :block_add_bxor, value, a)
            t2 = _binop_id(bc, :block_add_bxor, value, b)
            t3 = _binop_id(bc, :block_add_band, t1, t2)
            flag = _icmp_id(bc, ICMP_SLT, t3, emit_constant(bc, val_T(0)))
        else        # overflow ⟺ r <u a
            flag = _icmp_id(bc, ICMP_ULT, value, a)
        end
    elseif kind === :sub
        value = _binop_id(bc, :block_add_isub, a, b)
        if signed   # overflow ⟺ ((a ⊻ b) & (a ⊻ r)) < 0  (sign of r differs from a)
            t1 = _binop_id(bc, :block_add_bxor, a, b)
            t2 = _binop_id(bc, :block_add_bxor, a, value)
            t3 = _binop_id(bc, :block_add_band, t1, t2)
            flag = _icmp_id(bc, ICMP_SLT, t3, emit_constant(bc, val_T(0)))
        else        # overflow ⟺ a <u b  (borrow)
            flag = _icmp_id(bc, ICMP_ULT, a, b)
        end
    else  # kind === :mul — trap-free division check via a "safe" divisor
        value  = _binop_id(bc, :block_add_imul, a, b)
        i32z   = emit_constant(bc, Int32(0))     # Bool-domain false
        one    = emit_constant(bc, val_T(1))
        is_zero = _icmp_id(bc, ICMP_EQ, a, emit_constant(bc, val_T(0)))
        if signed
            # a==0  → no overflow; a==-1 → overflow iff b==typemin (the /-1 trap
            # case); else overflow iff (sdiv(r, a) != b). The divisor is made
            # safe (1 when a∈{0,-1}, else a) so sdiv never traps at runtime.
            neg1   = emit_constant(bc, val_T(-1))
            tmin   = emit_constant(bc, typemin(val_T))
            is_m1  = _icmp_id(bc, ICMP_EQ, a, neg1)
            disj   = _binop_id(bc, :block_add_bor, is_zero, is_m1)
            safe_a = _select_id(bc, disj, one, a)
            quot   = _binop_id(bc, :block_add_sdiv, value, safe_a)
            fdiv   = _icmp_id(bc, ICMP_NE, quot, b)
            fm1    = _icmp_id(bc, ICMP_EQ, b, tmin)
            inner  = _select_id(bc, is_m1, fm1, fdiv)
            flag   = _select_id(bc, is_zero, i32z, inner)
        else
            # a==0 → no overflow; else overflow iff (udiv(r, a) != b).
            safe_a = _select_id(bc, is_zero, one, a)
            quot   = _binop_id(bc, :block_add_udiv, value, safe_a)
            fdiv   = _icmp_id(bc, ICMP_NE, quot, b)
            flag   = _select_id(bc, is_zero, i32z, fdiv)
        end
    end

    bc.ssa_pairs[stmt_idx] = (value, flag)
    return nothing   # signal emit_instruction to skip the ssa_values recording
end

# === Invoke handling (overlay method calls) ===

# Helper: emit a constant for sizeof(eltype(T)) given an array SSA value or Argument.
function _emit_array_elem_size(bc::BuilderCtx, array_val, ir)
    T = nothing
    if array_val isa Core.Argument
        at = ir.argtypes[array_val.n]
        T = (at isa DataType && applicable(eltype, at)) ? eltype(at) : nothing
    elseif array_val isa Core.SSAValue
        st = ir.stmts[array_val.id]
        # st[:type] works on both old NamedTuple and new Instruction structs
        st_type = st[:type]
        T = (st_type isa DataType && applicable(eltype, st_type)) ? eltype(st_type) : nothing
    end
    es = (T isa DataType) ? sizeof(T) : 8  # default to Int64 elem size
    return emit_constant(bc, Int64(es))
end

function emit_invoke(bc::BuilderCtx, invoke_target, f, args, ir, stmt_idx)
    # invoke_target can be CodeInstance or MethodInstance
    if invoke_target isa Core.CodeInstance
        method = invoke_target.def.def     # CodeInstance → MethodInstance → Method
    elseif invoke_target isa Core.MethodInstance
        method = invoke_target.def          # MethodInstance → Method
    else
        error("Unknown invoke target type: $(typeof(invoke_target))")
    end
    fn_name = method.name

    # String operations — emit loads from known Julia String layout:
    #   ptr = pointer_from_objref(s) points to:
    #     offset 0: size_t length (Int64)
    #     offset 8: char data[] (inline, null-terminated)
    if fn_name == :ncodeunits && length(args) >= 1
        return emit_string_ncodeunits(bc, args, ir)
    elseif fn_name == :codeunit && length(args) >= 2
        return emit_string_codeunit(bc, args, ir)
    elseif fn_name == :sizeof && length(args) >= 1
        # sizeof(s::String) == ncodeunits(s)
        return emit_string_ncodeunits(bc, args, ir)
    elseif fn_name == :isempty && length(args) >= 1
        ncu_id = emit_string_ncodeunits(bc, args, ir)
        zero_id = emit_constant(bc, Int64(0))
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        cmp_id = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_EQ, ncu_id, zero_id)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, cmp_id, TYPE_I32)
    end

    # String concatenation. `a * b * ...` lowers either to `invoke Base._string(...)`
    # or (with literal/constant args) to `invoke *(::String,::String)` which inference
    # may constant-fold. Int `*` never reaches here (it's a :call intrinsic), so an
    # :invoke of :* / :_string with ≥2 args is string concat. Left-fold binary
    # __jl_string_concat over the operands (each resolved to a String ptr).
    if (fn_name == :_string || fn_name == :*) && length(args) >= 2
        string_type_ptr = pointer_from_objref(String)
        string_type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, string_type_ptr)))
        acc_id = resolve_operand(bc, args[1], ir)
        for i in 2:length(args)
            nxt_id = resolve_operand(bc, args[i], ir)
            acc_id = emit_call_runtime(bc, "__jl_string_concat",
                                       UInt32[acc_id, nxt_id, string_type_ptr_id])
        end
        return acc_id
    end

    # Array growth. `push!(a, x)` lowers to `invoke Base._growend_internal!(a, delta, oldsize)`
    # (the trailing element store re-derives the data ptr via a fresh getfield, so no
    # staleness). `resize!(a, n)` lowers to `invoke resize!(a, n)`. Both mutate in place;
    # the array jl_array_t* stays valid across (re)allocation.
    if fn_name == :_growend_internal! && length(args) >= 2
        a_id = resolve_operand(bc, args[1], ir)
        delta_id = resolve_operand(bc, args[2], ir)
        # TODO: derive from array type when _emit_array_elem_size works reliably
        elem_size_id = emit_constant(bc, Int64(8))
        return emit_call_runtime(bc, "__jl_array_grow_end", UInt32[a_id, delta_id, elem_size_id])
    end
    if fn_name == :resize! && length(args) >= 2
        a_id = resolve_operand(bc, args[1], ir)
        n_id = resolve_operand(bc, args[2], ir)
        elem_size_id = emit_constant(bc, Int64(8))
        return emit_call_runtime(bc, "__jl_array_resize", UInt32[a_id, n_id, elem_size_id])
    end

    # append! bulk copy: `unsafe_copyto!(dst_memref, src_memref, n)`. The two
    # memrefs arrive already tracked in ref_tracking (from prior memoryrefnew)
    # as (elem_addr_id, 0, T) — i.e. resolved 0-based element addresses. Copy
    # n*sizeof(T) bytes via __jl_memcpy. (The surrounding _growend_internal!
    # grow + setfield!(:size) in append!'s IR are handled above.)
    if fn_name == :unsafe_copyto! && length(args) >= 3
        dst_val, src_val, n_val = args[1], args[2], args[3]
        dst_tracked = (dst_val isa Core.SSAValue && haskey(bc.ref_tracking, dst_val)) ?
                      bc.ref_tracking[dst_val] : nothing
        src_tracked = (src_val isa Core.SSAValue && haskey(bc.ref_tracking, src_val)) ?
                      bc.ref_tracking[src_val] : nothing
        if dst_tracked !== nothing && src_tracked !== nothing
            dst_addr_id = dst_tracked[1]
            src_addr_id = src_tracked[1]
            elem_T = dst_tracked[3] isa DataType && length(dst_tracked[3].parameters) >= 2 ?
                     dst_tracked[3].parameters[2] : Int64
            elem_size = sizeof(elem_T)
            n_id = resolve_operand(bc, n_val, ir)
            if elem_size == 1
                nbytes_id = n_id
            else
                size_id = emit_constant(bc, Int64(elem_size))
                mul_ptr = Libdl.dlsym(bc.lib_handle, :block_add_imul)
                nbytes_id = ccall(mul_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                                  bc.fctx_handle, n_id, size_id)
            end
            return emit_call_runtime(bc, "__jl_memcpy",
                                     UInt32[dst_addr_id, src_addr_id, nbytes_id])
        end
    end

    # Unknown invoke — emit sentinel (e.g. bounds-error path, unreachable)
    iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
    return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                 bc.fctx_handle, Int64(0), TYPE_I32)
end

function emit_string_ncodeunits(bc, args, ir)
    ptr_id = resolve_operand(bc, args[1], ir)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                 bc.fctx_handle, ptr_id, Int32(0), TYPE_I64)
end

function emit_string_codeunit(bc, args, ir)
    ptr_id = resolve_operand(bc, args[1], ir)
    idx_id = resolve_operand(bc, args[2], ir)

    # Byte position: ptr + 8 + (idx - 1) = ptr + idx + 7
    # Step 1: compute addr = ptr + idx (one iadd)
    iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
    addr_id = ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, ptr_id, idx_id)
    # Step 2: load byte from addr + 7 (static offset)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    byte_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                    bc.fctx_handle, addr_id, Int32(7), TYPE_I8)
    # Step 3: uextend to i32 for return compatibility
    ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
    return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, byte_id, TYPE_I32)
end

# === GlobalRef handling (external function calls) ===

function emit_globalref(bc::BuilderCtx, f::Core.GlobalRef, args, ir, stmt_idx)
    fn = f.name
    mod = f.mod

    # === Integer arithmetic ===
    if fn == :add_int || fn == :+ ; return emit_binop(bc, :block_add_iadd, args, ir) end
    if fn == :sub_int || fn == :- ; return emit_binop(bc, :block_add_isub, args, ir) end
    if fn == :mul_int || fn == :* ; return emit_binop(bc, :block_add_imul, args, ir) end
    if fn == :sdiv_int ; return emit_binop(bc, :block_add_sdiv, args, ir) end
    if fn == :udiv_int ; return emit_binop(bc, :block_add_udiv, args, ir) end
    if fn == :srem_int || fn == :checked_srem_int ; return emit_binop(bc, :block_add_srem, args, ir) end
    if fn == :urem_int ; return emit_binop(bc, :block_add_urem, args, ir) end
    if fn == :checked_sdiv_int ; return emit_binop(bc, :block_add_sdiv, args, ir) end
    # checked {add,sub,mul} as GlobalRef (dual dispatch with emit_intrinsic):
    # return (value, overflowed::Bool) — materialized as a value-id pair.
    if fn == :checked_sadd_int ; return emit_checked_pair(bc, :add, true,  args, ir, stmt_idx) end
    if fn == :checked_uadd_int ; return emit_checked_pair(bc, :add, false, args, ir, stmt_idx) end
    if fn == :checked_ssub_int ; return emit_checked_pair(bc, :sub, true,  args, ir, stmt_idx) end
    if fn == :checked_usub_int ; return emit_checked_pair(bc, :sub, false, args, ir, stmt_idx) end
    if fn == :checked_smul_int ; return emit_checked_pair(bc, :mul, true,  args, ir, stmt_idx) end
    if fn == :checked_umul_int ; return emit_checked_pair(bc, :mul, false, args, ir, stmt_idx) end

    # === Integer comparisons ===
    if fn == :eq_int || fn === Symbol("===") ; return emit_icmp(bc, ICMP_EQ, args, ir) end
    if fn == :ne_int ; return emit_icmp(bc, ICMP_NE, args, ir) end
    if fn == :slt_int || fn == :< ; return emit_icmp(bc, ICMP_SLT, args, ir) end
    if fn == :sle_int || fn == :<= ; return emit_icmp(bc, ICMP_SLE, args, ir) end
    if fn == :ult_int ; return emit_icmp(bc, ICMP_ULT, args, ir) end
    if fn == :ule_int ; return emit_icmp(bc, ICMP_ULE, args, ir) end

    # === Integer bitwise (may also be used as not_int) ===
    if fn == :not_int ; return emit_not_int(bc, args, ir) end
    if fn == :and_int || fn == :& ; return emit_binop(bc, :block_add_band, args, ir) end
    if fn == :or_int || fn == :|  ; return emit_binop(bc, :block_add_bor, args, ir) end
    if fn == :xor_int ; return emit_binop(bc, :block_add_bxor, args, ir) end
    if fn == :shl_int ; return emit_binop(bc, :block_add_ishl, args, ir) end
    if fn == :add_ptr && length(args) >= 2 ; return emit_binop(bc, :block_add_iadd, args, ir) end
    if fn == :lshr_int ; return emit_binop(bc, :block_add_ushr, args, ir) end
    if fn == :ashr_int ; return emit_binop(bc, :block_add_sshr, args, ir) end
    # Bit-count / byte-swap (full-width correct; sub-word needs renormalization)
    if fn == :ctlz_int ; return emit_unop(bc, :block_add_clz, args, ir) end
    if fn == :cttz_int ; return emit_unop(bc, :block_add_ctz, args, ir) end
    if fn == :ctpop_int ; return emit_unop(bc, :block_add_popcnt, args, ir) end
    if fn == :bswap_int ; return emit_unop(bc, :block_add_bswap, args, ir) end
    if fn == :flipsign_int ; return emit_flipsign_int(bc, args, ir) end

    # === Float arithmetic ===
    if fn == :add_float ; return emit_binop(bc, :block_add_fadd, args, ir) end
    if fn == :sub_float ; return emit_binop(bc, :block_add_fsub, args, ir) end
    if fn == :mul_float ; return emit_binop(bc, :block_add_fmul, args, ir) end
    if fn == :div_float ; return emit_binop(bc, :block_add_fdiv, args, ir) end
    if fn == :neg_float ; return emit_unop(bc, :block_add_fneg, args, ir) end
    # Float math (unops; binop for copysign). Cranelift infers width from operand.
    if fn == :sqrt_llvm ; return emit_unop(bc, :block_add_sqrt, args, ir) end
    if fn == :ceil_llvm ; return emit_unop(bc, :block_add_ceil, args, ir) end
    if fn == :floor_llvm ; return emit_unop(bc, :block_add_floor, args, ir) end
    if fn == :trunc_llvm ; return emit_unop(bc, :block_add_trunc, args, ir) end
    if fn == :rint_llvm ; return emit_unop(bc, :block_add_nearest, args, ir) end
    if fn == :abs_float ; return emit_unop(bc, :block_add_fabs, args, ir) end
    if fn == :copysign_float ; return emit_binop(bc, :block_add_fcopysign, args, ir) end

    # === Float comparisons ===
    if fn == :eq_float ; return emit_fcmp(bc, FCMP_EQ, args, ir) end
    if fn == :ne_float ; return emit_fcmp(bc, FCMP_NE, args, ir) end
    if fn == :lt_float ; return emit_fcmp(bc, FCMP_LT, args, ir) end
    if fn == :le_float ; return emit_fcmp(bc, FCMP_LE, args, ir) end

    # === Conversions ===
    if fn == :zext_int ; return emit_convert(bc, :block_add_uextend, args, ir) end
    if fn == :sext_int ; return emit_convert(bc, :block_add_sextend, args, ir) end
    if fn == :trunc_int ; return emit_trunc(bc, args, ir) end
    # int <-> float (Type is the *result* type, in args[1])
    if fn == :sitofp ; return emit_convert(bc, :block_add_fcvt_from_sint, args, ir) end
    if fn == :uitofp ; return emit_convert(bc, :block_add_fcvt_from_uint, args, ir) end
    if fn == :fptosi ; return emit_convert(bc, :block_add_fcvt_to_sint_sat, args, ir) end
    if fn == :fptoui ; return emit_convert(bc, :block_add_fcvt_to_uint_sat, args, ir) end
    if fn == :fpext  ; return emit_convert(bc, :block_add_fpromote, args, ir) end
    if fn == :fptrunc ; return emit_convert(bc, :block_add_fdemote, args, ir) end

    # === Struct field access ===
    if fn == :getfield && length(args) >= 2
        return emit_struct_getfield(bc, args, ir, stmt_idx)
    end
    if fn == :setfield! && length(args) >= 3
        return emit_struct_setfield(bc, args, ir)
    end

    # === Pointer / memory operations ===
    if fn == :bitcast && length(args) >= 2
        # bitcast is a no-op at the IR level — same bits, different type
        return resolve_operand(bc, args[2], ir)
    end

    if fn == :pointerref && length(args) >= 2
        return emit_pointerref(bc, args, ir)
    end

    if fn == :pointerset && length(args) >= 3
        return emit_pointerset(bc, args, ir)
    end

    # === Runtime allocation intrinsics ===
    if fn == :memorynew
        # Core.memorynew(Memory{T}, n) → allocates raw memory for n elements
        return emit_memorynew(bc, args, ir)
    end
    if fn == :__jl_string_new && length(args) == 1
        # __jl_string_new(length) → create new string
        len_id = resolve_operand(bc, args[1], ir)
        # Allocate string with space for length + null terminator
        total_size_id = emit_constant(bc, Int32(8))  # length + data + null
        type_ptr = pointer_from_objref(String)
        type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))

        # Call Julia-compatible allocation
        str_ptr_id = emit_call_runtime(bc, "__jl_gc_alloc_array_julia",
            UInt32[type_ptr_id, len_id, total_size_id])

        # Store length at offset 0 (String layout)
        len_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
        ccall(len_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
              bc.fctx_handle, str_ptr_id, Int32(0), len_id, TYPE_I64)

        return str_ptr_id
    end
    if fn == :memoryrefnew && length(args) == 1
        # Core.memoryrefnew(mem::Memory{T}) → creates MemoryRef from raw memory
        return emit_memoryref_from_mem(bc, args, ir, stmt_idx)
    end
    if fn == :tuple && length(args) >= 1
        # Core.tuple(elements...) → create a tuple value
        return emit_core_tuple(bc, args, ir)
    end

    # === MemoryRef managed-memory operators ===
    if fn == :memoryrefnew && length(args) >= 2
        return emit_memoryrefnew(bc, args, ir, stmt_idx)
    end
    if fn == :memoryrefget && length(args) >= 1
        return emit_memoryrefget(bc, args, ir)
    end
    if fn == :memoryrefset! && length(args) >= 2
        return emit_memoryrefset(bc, args, ir)
    end
    if fn == :memoryrefoffset && length(args) >= 1
        # memoryrefoffset(ref::MemoryRef{T}) → Int64 (1-based element index)
        # For a fresh MemoryRef from a Vector's :ref field, byte_offset==0, so result==1.
        # General: byte_offset / elem_size + 1.
        memref_val = args[1]
        tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
                  bc.ref_tracking[memref_val] : nothing
        if tracked !== nothing
            _, byte_off, memref_T = tracked
            elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
                     memref_T.parameters[2] : Int64
            elem_index = Int64(byte_off ÷ sizeof(elem_T)) + Int64(1)
            return emit_constant(bc, elem_index)
        end
        # Fallback: return constant 1 (valid for all non-sliced arrays)
        return emit_constant(bc, Int64(1))
    end
    if fn == :throw
        # Base.throw(...) — always Union{}-typed (never returns). Emit trap.
        trap_ptr = Libdl.dlsym(bc.lib_handle, :block_add_trap)
        ccall(trap_ptr, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
        return nothing
    end

    error("Unsupported GlobalRef: $(mod).$(fn)")
end

# === Struct field helpers ===

function get_operand_type(val, ir)
    if val isa Core.Argument
        T = ir.argtypes[val.n]
    elseif val isa Core.SSAValue
        T = ir.stmts[val.id][:type]
    elseif val isa Core.Const
        # For constants, get the type of the contained value
        return typeof(val.val)
    else
        return typeof(val)
    end
    # Unwrap Julia inference artifacts that aren't real DataTypes, so callers
    # that feed this into DataType-typed slots (ref_tracking, cranelift_type,
    # fieldoffset, etc.) get a concrete type. PartialStruct.typ is the
    # underlying DataType (e.g. PartialStruct(Memory{Int64},...) → Memory{Int64}).
    T isa Core.PartialStruct && return T.typ
    T isa Core.Const && return typeof(T.val)
    return T
end

# getfield(constant_tuple, dynamic_index) → select chain over the tuple elements.
# tuple_val is a Julia Tuple of constants; idx resolves to a 1-based index value.
function emit_tuple_index(bc::BuilderCtx, tuple_val, idx, ir)
    idx_id = resolve_operand(bc, idx, ir)
    elem_ids = UInt32[emit_constant(bc, e) for e in tuple_val]
    n = length(elem_ids)
    n == 1 && return elem_ids[1]
    icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
    iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
    select_ptr = Libdl.dlsym(bc.lib_handle, :block_add_select)
    # Right-to-left: acc = en; for i = n-1..1: acc = select(idx==i, ei, acc)
    acc = elem_ids[n]
    for i in (n - 1):-1:1
        i_id = ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(i), TYPE_I64)
        cmp = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                    bc.fctx_handle, ICMP_EQ, idx_id, i_id)
        acc = ccall(select_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                    bc.fctx_handle, cmp, elem_ids[i], acc)
    end
    return acc
end

# getfield on a RUNTIME-built tuple: `obj` is an SSA value / Argument of a concrete
# Tuple type — the heap pointer produced by `emit_core_tuple` (n≥2) or the
# pass-through element (n==1). Load each field from the pointer at `fieldoffset`
# (which matches `emit_core_tuple`'s aligned stores) and either return the one
# requested field (constant index) or select over a dynamic index. This is how
# array literals with runtime elements (`[a, b, c]`) read their values back.
function emit_tuple_index_from_ssa(bc::BuilderCtx, obj, idx, ir)
    T = get_operand_type(obj, ir)
    T = T isa Core.Const ? T.val : T
    (T isa DataType && isconcretetype(T) && T <: Tuple) ||
        throw(CompileError("dynamic getfield on non-concrete tuple type $T"))
    elem_types = Any[T.parameters...]
    n = length(elem_types)
    # n==1: emit_core_tuple passed the element through (no allocation); obj IS it.
    n == 1 && return resolve_operand(bc, obj, ir)

    # select() needs matching operand Cranelift types; array literals are
    # homogeneous. Heterogeneous dynamic indexing is unsupported (loud failure).
    first_ct = cranelift_type(elem_types[1])
    all(i -> cranelift_type(elem_types[i]) == first_ct, 2:n) ||
        throw(CompileError("heterogeneous dynamic tuple indexing not supported ($T)"))

    ptr_id = resolve_operand(bc, obj, ir)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    elem_ids = UInt32[]
    for i in 1:n
        off = Int32(fieldoffset(T, i))
        ct = cranelift_type(elem_types[i])
        push!(elem_ids, ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                              bc.fctx_handle, ptr_id, off, ct))
    end

    # Constant index → single load (also fixes the latent bitstype-path miscompile
    # where the tuple POINTER was treated as the value).
    k = idx isa Core.QuoteNode ? idx.value : idx
    if k isa Integer
        (1 ≤ k ≤ n) || throw(CompileError("tuple index $k out of range (1:$n)"))
        return elem_ids[k]
    end

    # Dynamic index → right-to-left select chain (mirrors emit_tuple_index).
    idx_id = resolve_operand(bc, idx, ir)
    icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
    iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
    select_ptr = Libdl.dlsym(bc.lib_handle, :block_add_select)
    acc = elem_ids[n]
    for i in (n - 1):-1:1
        i_id = ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(i), TYPE_I64)
        cmp = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                    bc.fctx_handle, ICMP_EQ, idx_id, i_id)
        acc = ccall(select_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                    bc.fctx_handle, cmp, elem_ids[i], acc)
    end
    return acc
end

function emit_struct_getfield(bc::BuilderCtx, args, ir, stmt_idx)
    obj = args[1]
    # checked-arithmetic pair: getfield(pair, 1)=value, getfield(pair, 2)=flag.
    # The pair stmt stored two value ids in bc.ssa_pairs (no tuple allocation).
    if obj isa Core.SSAValue && haskey(bc.ssa_pairs, obj.id)
        k = args[2]
        k isa QuoteNode && (k = k.value)
        k isa Integer || throw(CompileError("non-constant index into checked pair"))
        pair = bc.ssa_pairs[obj.id]
        return k == 1 ? pair[1] : pair[2]
    end
    # Dynamic index into a constant tuple, e.g. getfield((1,2,3,4), %i, false),
    # which is how array literals read their initial values in a loop. Lower to a
    # select chain over the constant elements (no select-free alternative without
    # new blocks/phi nodes).
    if obj isa Tuple && length(args) >= 2 &&
       (args[2] isa Core.SSAValue || args[2] isa Core.Argument || args[2] isa Integer)
        return emit_tuple_index(bc, obj, args[2], ir)
    end
    # Runtime tuple: obj is an SSA/Argument of concrete Tuple type (the heap
    # pointer from Core.tuple/emit_core_tuple). Lower getfield to per-field loads
    # + select — this is how array literals with runtime elements ([a,b,c]) read
    # their values back. (Handles constant AND dynamic index; before this, a
    # constant index miscompiled via the bitstype path and a dynamic index erred.)
    if (obj isa Core.SSAValue || obj isa Core.Argument) && length(args) >= 2
        local oT = get_operand_type(obj, ir)
        oT = oT isa Core.Const ? oT.val : oT
        if oT isa DataType && isconcretetype(oT) && oT <: Tuple
            return emit_tuple_index_from_ssa(bc, obj, args[2], ir)
        end
    end
    field_sym = args[2] isa QuoteNode ? args[2].value :
                args[2] isa Symbol ? args[2] :
                args[2] isa Integer ? args[2] :
                error("Expected QuoteNode/Symbol/Integer for field, got $(typeof(args[2]))")

    T = get_operand_type(obj, ir)
    T = T isa Core.Const ? T.val : T

    # Case 1: composed offset from ref_tracking (e.g. memref.ptr_or_offset)
    if obj isa Core.SSAValue && haskey(bc.ref_tracking, obj)
        base_id, base_off, parent_T = bc.ref_tracking[obj]
        field_off = fieldoffset(parent_T, field_sym)
        field_T = fieldtype(parent_T, field_sym)
        field_type_enum = cranelift_type(field_T)
        load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
        return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                     bc.fctx_handle, base_id, Int32(base_off + field_off), field_type_enum)
    end

    obj_id = resolve_operand(bc, obj, ir)

    # Case 2: field is a non-loadable type (e.g. MemoryRef) — track composed offset
    field_T = fieldtype(T, field_sym)
    field_loadable = try
        cranelift_type(field_T); true
    catch _
        false
    end

    if !field_loadable && (T isa DataType)
        # Union{Nothing, T} where T is a heap-allocated type: load field as raw
        # pointer. nothing → null(0), a value → its heap pointer. Must handle
        # BEFORE ref_tracking — the ref_tracking dict expects Tuple{UInt32,
        # Int64, DataType} and a Union type causes convert(DataType, Union).
        if field_T isa Union
            # Union{a, b} — check for Union{Nothing, PointerType}
            a_T, b_T = field_T.a, field_T.b  # avoids Base.uniontypes allocation
            other_T = a_T === Nothing ? b_T :
                      b_T === Nothing ? a_T : nothing
            if other_T !== nothing && other_T isa DataType && is_ptr_type(other_T)
                offset = fieldoffset(T, field_sym)
                load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
                result = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                              bc.fctx_handle, obj_id, Int32(offset), TYPE_PTR)
                return result
            end
        end
        # Track composed offset for later getfield sub-accesses
        offset = fieldoffset(T, field_sym)
        bc.ref_tracking[Core.SSAValue(stmt_idx)] = (obj_id, offset, field_T)
        # Return a sentinel Cranelift value — the real value is in ref_tracking
        return obj_id
    end

    # Case 3: bitstype struct field — extract from value (not memory load)
    if T isa DataType && isbitstype(T)
        # Bitstype getfield: value is in register, extract field by offset
        offset = fieldoffset(T, field_sym)
        if offset == 0
            return obj_id  # value is the field itself
        end

        # Multi-field bitstype: extract with shift/mask operations
        field_T = fieldtype(T, field_sym)
        field_size = sizeof(field_T) * 8  # field size in bits
        struct_size = sizeof(T) * 8        # struct size in bits

        # Shift right by offset bits to bring field to LSB position
        offset_id = emit_constant(bc, Int64(offset * 8))
        shift_ptr = Libdl.dlsym(bc.lib_handle, :block_add_ushr)
        shifted_id = ccall(shift_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                          bc.fctx_handle, obj_id, offset_id)

        # Create mask to extract only the field bits
        mask = (UInt64(1) << field_size) - UInt64(1)  # mask for field bits

        # Use consistent type for mask based on struct size
        if struct_size <= 32
            mask_id = emit_constant(bc, Int32(mask & 0xFFFFFFFF))
        else
            mask_id = emit_constant(bc, Int64(mask))
        end

        # Apply mask
        and_ptr = Libdl.dlsym(bc.lib_handle, :block_add_band)
        masked_id = ccall(and_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                         bc.fctx_handle, shifted_id, mask_id)

        # Sign extend if field type is signed and smaller than struct size
        if field_T <: Signed && field_size < struct_size
            # Sign extend from field_size to struct_size
            target_type = cranelift_type(field_T)
            sext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_sextend)
            return ccall(sext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                          bc.fctx_handle, masked_id, target_type)
        else
            return masked_id
        end
    end

    # Case 4: regular mutable struct field — load from memory
    offset = fieldoffset(T, field_sym)
    field_type_enum = cranelift_type(field_T)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                 bc.fctx_handle, obj_id, Int32(offset), field_type_enum)
end

function emit_struct_setfield(bc::BuilderCtx, args, ir)
    obj = args[1]
    field_sym = args[2] isa QuoteNode ? args[2].value :
                args[2] isa Symbol ? args[2] :
                error("Expected QuoteNode or Symbol for field name, got $(typeof(args[2]))")
    value = args[3]

    T = get_operand_type(obj, ir)
    T = T isa Core.Const ? T.val : T

    obj_id = resolve_operand(bc, obj, ir)
    val_id = resolve_operand(bc, value, ir)

    offset = fieldoffset(T, field_sym)
    field_T = fieldtype(T, field_sym)
    field_type_enum = cranelift_type(field_T)

    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
          bc.fctx_handle, obj_id, Int32(offset), val_id, field_type_enum)

    # setfield! returns the stored value
    return val_id
end

# === Pointer operations ===

function emit_pointerref(bc::BuilderCtx, args, ir)
    # pointerref(ptr::Ptr{T}, i::Int, align) — load element at 1-based index i
    ptr_id = resolve_operand(bc, args[1], ir)
    idx_id = resolve_operand(bc, args[2], ir)

    # Determine element type from the pointer type
    ptr_type = get_operand_type(args[1], ir)
    ptr_type = ptr_type isa Core.Const ? ptr_type.val : ptr_type
    elem_T = ptr_type isa DataType && ptr_type <: Ptr && length(ptr_type.parameters) > 0 ?
             ptr_type.parameters[1] : Int64
    elem_size = sizeof(elem_T)

    # Compute element address: ptr + (idx - 1) * elem_size
    # idx - 1
    one_id = if elem_size == 8
        emit_constant(bc, Int64(1))
    else
        emit_constant(bc, Int32(1))
    end
    sub_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    idx_0_id = ccall(sub_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, idx_id, one_id)

    # (idx - 1) * elem_size
    if elem_size != 1
        size_id = if elem_size == 8
            emit_constant(bc, Int64(elem_size))
        else
            emit_constant(bc, Int32(elem_size))
        end
        mul_ptr = Libdl.dlsym(bc.lib_handle, :block_add_imul)
        byte_off_id = ccall(mul_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                             bc.fctx_handle, idx_0_id, size_id)
    else
        byte_off_id = idx_0_id  # elem_size == 1, no multiply needed
    end

    # ptr + byte_offset
    iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
    elem_addr_id = ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                          bc.fctx_handle, ptr_id, byte_off_id)

    # Load element at elem_addr + 0
    elem_type_enum = cranelift_type(elem_T)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                 bc.fctx_handle, elem_addr_id, Int32(0), elem_type_enum)
end

function emit_pointerset(bc::BuilderCtx, args, ir)
    # pointerset(ptr::Ptr{T}, val, i::Int, align) — store val at 1-based index i
    ptr_id = resolve_operand(bc, args[1], ir)
    val_id = resolve_operand(bc, args[2], ir)
    idx_id = resolve_operand(bc, args[3], ir)

    # Determine element type from the pointer type
    ptr_type = get_operand_type(args[1], ir)
    ptr_type = ptr_type isa Core.Const ? ptr_type.val : ptr_type
    elem_T = ptr_type isa DataType && ptr_type <: Ptr && length(ptr_type.parameters) > 0 ?
             ptr_type.parameters[1] : Int64
    elem_size = sizeof(elem_T)

    # Compute element address: ptr + (idx - 1) * elem_size
    one_id = if elem_size == 8
        emit_constant(bc, Int64(1))
    else
        emit_constant(bc, Int32(1))
    end
    sub_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    idx_0_id = ccall(sub_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, idx_id, one_id)

    if elem_size != 1
        size_id = if elem_size == 8
            emit_constant(bc, Int64(elem_size))
        else
            emit_constant(bc, Int32(elem_size))
        end
        mul_ptr = Libdl.dlsym(bc.lib_handle, :block_add_imul)
        byte_off_id = ccall(mul_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                             bc.fctx_handle, idx_0_id, size_id)
    else
        byte_off_id = idx_0_id
    end

    iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
    elem_addr_id = ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                          bc.fctx_handle, ptr_id, byte_off_id)

    # Store val at elem_addr + 0
    elem_type_enum = cranelift_type(elem_T)
    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
          bc.fctx_handle, elem_addr_id, Int32(0), val_id, elem_type_enum)

    # pointerset returns the pointer (first argument)
    return ptr_id
end

# === MemoryRef managed-memory operators ===

function emit_memoryrefnew(bc::BuilderCtx, args, ir, stmt_idx)
    # memoryrefnew(memref::MemoryRef{T}, idx::Int, ordered::Bool) → MemoryRef{T}
    # Creates a new MemoryRef pointing to element at 1-based index idx.
    memref_val = args[1]
    idx_val = args[2]

    # Get the MemoryRef's base info from ref_tracking
    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing
    tracked === nothing && error("memoryrefnew: operand not a tracked MemoryRef")

    base_id, base_off, memref_T = tracked
    elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_size = sizeof(elem_T)

    # Load data pointer from base + base_off (field ptr_or_offset at offset 0)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    data_ptr_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                        bc.fctx_handle, base_id, Int32(base_off), TYPE_I64)

    # Compute element offset: (idx - 1) * elem_size
    idx_id = resolve_operand(bc, idx_val, ir)
    one_id = emit_constant(bc, Int64(1))
    sub_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    idx_0_id = ccall(sub_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, idx_id, one_id)

    if elem_size != 1
        size_id = emit_constant(bc, Int64(elem_size))
        mul_ptr = Libdl.dlsym(bc.lib_handle, :block_add_imul)
        byte_off_id = ccall(mul_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                             bc.fctx_handle, idx_0_id, size_id)
    else
        byte_off_id = idx_0_id
    end

    # Compute element address = data_ptr + byte_offset
    iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
    elem_addr_id = ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                          bc.fctx_handle, data_ptr_id, byte_off_id)

    # Track the new MemoryRef — offset 0 since elem_addr_id IS the exact address
    bc.ref_tracking[Core.SSAValue(stmt_idx)] = (elem_addr_id, 0, memref_T)
    return elem_addr_id
end

function emit_memoryrefget(bc::BuilderCtx, args, ir)
    # memoryrefget(memref::MemoryRef{T}, ordering, ordered) → T
    memref_val = args[1]

    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing
    tracked === nothing && error("memoryrefget: operand not a tracked MemoryRef")

    base_id, base_off, memref_T = tracked
    elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_type_enum = cranelift_type(elem_T)

    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                 bc.fctx_handle, base_id, Int32(base_off), elem_type_enum)
end

function emit_memoryrefset(bc::BuilderCtx, args, ir)
    # memoryrefset!(memref::MemoryRef{T}, val, ordering, ordered) → T
    memref_val = args[1]
    val = args[2]

    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing
    tracked === nothing && error("memoryrefset!: operand not a tracked MemoryRef")

    base_id, base_off, memref_T = tracked
    elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_type_enum = cranelift_type(elem_T)

    val_id = resolve_operand(bc, val, ir)

    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
          bc.fctx_handle, base_id, Int32(base_off), val_id, elem_type_enum)

    # memoryrefset! returns the stored value
    return val_id
end

function emit_isa(bc::BuilderCtx, args, ir)
    # isa(x, Type) — currently only handles isa(x, Nothing) on pointer values.
    # args[1] = value, args[2] = the type to check against (Nothing / QuoteNode / Const)
    target_type = args[2]
    target_type isa QuoteNode && (target_type = target_type.value)
    target_type isa Core.Const && (target_type = target_type.val)
    if target_type === Nothing
        val_id = resolve_operand(bc, args[1], ir)
        zero_id = emit_constant(bc, Int64(0))
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                      bc.fctx_handle, ICMP_EQ, val_id, zero_id)
        # uextend I8 → I32 for Bool ABI
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, result, TYPE_I32)
    end
    throw(CompileError("unsupported isa target: $target_type"))
end

function emit_memoryrefunset(bc::BuilderCtx, args, ir)
    # memoryrefunset!(memref::MemoryRef{T}, ordering, boundscheck) → Nothing
    # Stores zero at the MemoryRef address (GC safety for reference types).
    memref_val = args[1]

    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing
    tracked === nothing && error("memoryrefunset!: operand not a tracked MemoryRef")

    base_id, base_off, memref_T = tracked
    elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
    elem_type_enum = cranelift_type(elem_T)

    zero_id = emit_constant(bc, Int64(0))
    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
          bc.fctx_handle, base_id, Int32(base_off), zero_id, elem_type_enum)

    return nothing
end

# === Runtime allocation ===

function _declare_imports(bc::BuilderCtx)
    declare_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_import)
    # __jl_gc_alloc_array(type_tag: u32, length: i32, elem_size: u32) -> *mut u8
    int32s = UInt32[TYPE_I32, TYPE_I32, TYPE_I32]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_gc_alloc_array", TYPE_PTR, int32s, length(int32s))
    # __jl_gc_alloc(type_tag: u32, data_size: u32) -> *mut u8
    int32_2 = UInt32[TYPE_I32, TYPE_I32]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_gc_alloc", TYPE_PTR, int32_2, length(int32_2))

    # Julia-compatible allocation functions
    # __jl_gc_alloc_julia(type_ptr: *mut u8, data_size: u32) -> *mut u8
    julia_alloc_args = UInt32[TYPE_PTR, TYPE_I32]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_gc_alloc_julia", TYPE_PTR, julia_alloc_args, length(julia_alloc_args))

    # __jl_gc_alloc_array_julia(type_ptr: *mut u8, length: i32, elem_size: u32) -> *mut u8
    julia_array_args = UInt32[TYPE_PTR, TYPE_I32, TYPE_I32]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_gc_alloc_array_julia", TYPE_PTR, julia_array_args, length(julia_array_args))

    # __jl_array_new_1d(atype: *mut u8, nel: i64, elem_size: i64) -> *mut u8  (pure-Rust)
    array_new_args = UInt32[TYPE_PTR, TYPE_I64, TYPE_I64]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_array_new_1d", TYPE_PTR, array_new_args, length(array_new_args))

    # __jl_string_concat(a: ptr, b: ptr, string_type_ptr: ptr) -> ptr  (pure-Rust)
    str_concat_args = UInt32[TYPE_PTR, TYPE_PTR, TYPE_PTR]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_string_concat", TYPE_PTR, str_concat_args, length(str_concat_args))

    # Array growth/shrink (pure-Rust, needs elem_size).
    for fn in ("__jl_array_grow_end", "__jl_array_del_end", "__jl_array_resize")
        grow_args = UInt32[TYPE_PTR, TYPE_I64, TYPE_I64]
        ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
              bc.builder_handle, fn, TYPE_PTR, grow_args, length(grow_args))
    end
    # Bulk byte copy for append! / unsafe_copyto! between array data regions.
    memcpy_args = UInt32[TYPE_PTR, TYPE_PTR, TYPE_I64]
    ccall(declare_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, "__jl_memcpy", TYPE_PTR, memcpy_args, length(memcpy_args))
end

function emit_call_runtime(bc::BuilderCtx, func_name::String, arg_ids::Vector{UInt32})
    call_ptr = Libdl.dlsym(bc.lib_handle, :block_add_call)
    nargs = length(arg_ids)
    return ccall(call_ptr, UInt32,
                 (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt32}, Csize_t),
                 bc.fctx_handle, bc.builder_handle, func_name, arg_ids, nargs)
end

function emit_memorynew(bc::BuilderCtx, args, ir)
    # Core.memorynew(Memory{T}, n) → allocate raw memory with Julia-compatible layout
    mem_T = args[1]  # Memory{Int64} DataType
    n = args[2]      # length

    elem_T = mem_T isa DataType && length(mem_T.parameters) >= 2 ?
             mem_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_size = UInt32(sizeof(elem_T))

    n_id = resolve_operand(bc, n, ir)
    # __jl_gc_alloc_array_julia expects i32 — reduce from i64
    ireduce_ptr = Libdl.dlsym(bc.lib_handle, :block_add_ireduce)
    n32_id = ccall(ireduce_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                   bc.fctx_handle, n_id, TYPE_I32)

    # Get Julia type pointer for the array type (Vector{T})
    array_T = Vector{elem_T}
    type_ptr = pointer_from_objref(array_T)

    elem_size_id = emit_constant(bc, Int32(elem_size))
    type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))

    # Call __jl_gc_alloc_array_julia using the builder's runtime call mechanism
    # This creates Julia-compatible array layout that can be safely returned to Julia
    ptr_id = emit_call_runtime(bc, "__jl_gc_alloc_array_julia",
        UInt32[type_ptr_id, n32_id, elem_size_id])

    return ptr_id
end

function emit_memoryref_from_mem(bc::BuilderCtx, args, ir, stmt_idx)
    # Core.memoryrefnew(mem::Memory{T}) → create MemoryRef from raw allocation
    # The memory pointer IS the data pointer. Track for later memoryrefget/setfield
    mem_id = resolve_operand(bc, args[1], ir)
    mem_T = get_operand_type(args[1], ir)
    mem_T = mem_T isa Core.Const ? mem_T.val : mem_T

    # Track with offset 0 — the pointer from alloc already points to element data
    # Memory/MemoryRef types have same param structure (ordering, T, addrspace)
    bc.ref_tracking[Core.SSAValue(stmt_idx)] = (mem_id, 0, mem_T)
    return mem_id
end

function emit_core_tuple(bc::BuilderCtx, args, ir)
    # Core.tuple(elements...) → creates a Tuple
    # For single-element Tuple{Int64}, sizeof=8, pass through
    if length(args) == 1
        return resolve_operand(bc, args[1], ir)
    end

    # Multi-element tuple: allocate and store elements
    # Calculate tuple layout and size
    elem_types = [get_operand_type(a, ir) for a in args]
    elem_types = [t isa Core.Const ? t.val : t for t in elem_types]

    # Calculate offsets for each element (tuple fields are aligned)
    offsets = Int[]
    current_offset = 0
    for ET in elem_types
        # Align to natural boundary of the type
        align = sizeof(ET)
        current_offset = cld(current_offset, align) * align
        push!(offsets, current_offset)
        current_offset += sizeof(ET)
    end

    total_size = current_offset

    # For tuples, we need to allocate a chunk of memory for the elements
    # Since tuples are immutable and fixed-size, we can use a simple allocation
    # Allocate memory for tuple elements (using struct allocation)

    # Construct the actual tuple type from element types
    tuple_type = Tuple{elem_types...}
    type_ptr = pointer_from_objref(tuple_type)  # Use actual tuple type pointer
    size_id = emit_constant(bc, Int32(total_size))
    type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))

    # Call __jl_gc_alloc_julia for the memory (tuples are structs, not arrays)
    ptr_id = emit_call_runtime(bc, "__jl_gc_alloc_julia",
        UInt32[type_ptr_id, size_id])

    # Store each element at its calculated offset
    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    for (i, arg) in enumerate(args)
        elem_id = resolve_operand(bc, arg, ir)
        elem_T = elem_types[i]
        field_type_enum = cranelift_type(elem_T)
        ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
              bc.fctx_handle, ptr_id, Int32(offsets[i]), elem_id, field_type_enum)
    end

    return ptr_id
end

function emit_new(bc::BuilderCtx, T, field_args, ir, stmt_idx)
    # %new(T, fields...) — construct a new struct with Julia-compatible allocation
    # T can be: Core.Const, Core.GlobalRef, or direct DataType
    if T isa Core.Const
        T = T.val
    elseif T isa Core.GlobalRef
        T = getglobal(T.mod, T.name)
    elseif T isa Core.SSAValue
        T = ir.stmts[T.id][:type]
        T = T isa Core.Const ? T.val : T
    end

    # Arrays: allocate a REAL Julia array via jl_alloc_array_1d. The fake struct
    # layout can't represent a returnable jl_array_t, so hand off to Julia's own
    # allocator. Subsequent getfield(%new, :ref)/memoryrefset! element stores then
    # work exactly as they do for arrays passed in from Julia. field_args is
    # (memref, size_tuple); only the 1-d constant size_tuple is supported here.
    # NOTE: restrict to `Array` — `AbstractArray` would also catch UnitRange and
    # other ranges (Range <: AbstractVector <: AbstractArray), which are 2-field
    # immutable index objects, not contiguous arrays.
    if T isa DataType && T <: Array
        size_arg = field_args[end]
        if !(size_arg isa Tuple) || length(size_arg) != 1
            error("emit_new(array): only 1-d arrays with constant size supported, got size $size_arg")
        end
        nel = size_arg[1]
        elem_size = sizeof(eltype(T))
        type_ptr = pointer_from_objref(T)
        type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))
        nel_id = emit_constant(bc, Int64(nel))
        elem_size_id = emit_constant(bc, Int64(elem_size))
        return emit_call_runtime(bc, "__jl_array_new_1d", UInt32[type_ptr_id, nel_id, elem_size_id])
    end

    # Ranges (UnitRange, StepRange, …) appear ONLY in dead bounds-error-report
    # paths (`_throw_boundserror_indices(a, range)`), which trap. Emit a sentinel
    # — the value is never observed at runtime.
    if T isa DataType && T <: AbstractRange
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, Int64(0), TYPE_I64)
    end

    # Bitstype immutable struct — pack fields into a register via uextend + ishl +
    # bor (the inverse of the existing getfield Case 3 ushr + band extraction).
    # Only ≤8-byte structs (cranelift_type succeeds); larger need multi-register.
    if T isa DataType && isbitstype(T)
        ct = cranelift_type(T)
        field_ids = [resolve_operand(bc, fa, ir) for fa in field_args]
        nf = length(field_ids)
        nf == 0 && return emit_constant(bc, Int64(0))
        uext_ptr  = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        shl_ptr   = Libdl.dlsym(bc.lib_handle, :block_add_ishl)
        bor_ptr   = Libdl.dlsym(bc.lib_handle, :block_add_bor)
        acc_id = emit_constant(bc, Int64(0))
        for i in 1:nf
            f_id = field_ids[i]
            bitpos = fieldoffset(T, i) * 8
            field_type_enum = cranelift_type(fieldtype(T, i))
            if field_type_enum != ct
                f_id = ccall(uext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                             bc.fctx_handle, f_id, ct)
            end
            if bitpos != 0
                shift_id = emit_constant(bc, Int64(bitpos))
                f_id = ccall(shl_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                             bc.fctx_handle, f_id, shift_id)
            end
            acc_id = ccall(bor_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                           bc.fctx_handle, f_id, acc_id)
        end
        return acc_id
    end

    if !(T isa DataType) || !isconcretetype(T)
        error("new only supported for concrete types, got $T ($(typeof(T)))")
    end

    # Resolve all field values
    field_ids = UInt32[resolve_operand(bc, fa, ir) for fa in field_args]

    # Get Julia type pointer for Julia-compatible allocation
    type_ptr = pointer_from_objref(T)
    data_size = UInt32(sizeof(T))

    # Allocate using Julia-compatible runtime call
    # __jl_gc_alloc_julia(type_ptr: *mut u8, data_size: u32) -> *mut u8
    type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))
    size_id = emit_constant(bc, Int32(data_size))

    # Use the builder's runtime call mechanism
    ptr_id = emit_call_runtime(bc, "__jl_gc_alloc_julia", UInt32[type_ptr_id, size_id])

    # Store each field at its offset
    field_names = fieldnames(T)
    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    for (i, fid) in enumerate(field_ids)
        offset = Int32(fieldoffset(T, i))
        field_T = fieldtype(T, i)
        field_type_enum = cranelift_type(field_T)
        ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
              bc.fctx_handle, ptr_id, offset, fid, field_type_enum)
    end

    return ptr_id
end

# === Find native-builder library ===

# Delegate to NativeCodegen._init_builder_lib (defined in NativeCodegen.jl) so the
# builder .dylib is resolved the same way as the runtime .a: dev-profile (debug)
# ONLY, via _debug_artifact. Release artifacts are never loaded in local
# development — they carry no debug-assertions and a stale release .dylib has
# silently shadowed a fresh debug one, masking real bugs. _init_builder_lib
# memoizes the resolved path in _BUILDER_LIB_PATH.
function get_native_builder_lib()
    _init_builder_lib()
end
