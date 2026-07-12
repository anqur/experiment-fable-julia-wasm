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
const TYPE_I16 = UInt32(6)
const TYPE_VOID = UInt32(7)  # void return (maps to None → no return type)

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
    # Symbol and Int128/UInt128 — always TYPE_PTR (immutable heap objects)
    T === Symbol && return TYPE_PTR
    (T === Int128 || T === UInt128) && return TYPE_PTR
    T isa DataType && Base.ismutabletype(T) && !(T <: Ptr) && return TYPE_PTR
    # Handle tuples as pointer types (multi-element tuples need memory allocation)
    T isa DataType && T <: Tuple && return TYPE_PTR
    # Immutable non-bitstype structs with heap fields (e.g. GreenNode, Wrapper)
    # are also pointers. Exclude MemoryRef/Memory (need Case 2 ref_tracking).
    _is_heap_struct(T) && return TYPE_PTR
    r = try scalar_repr(T) catch _; nothing end
    if r !== nothing
        return r.vt == WasmCodegen.I64 ? TYPE_I64 : r.vt == WasmCodegen.I32 ? TYPE_I32 :
               r.vt == WasmCodegen.F64 ? TYPE_F64 : TYPE_F32
    end
    # Bitstypes: map to Cranelift type by sizeof
    if T isa DataType && isbitstype(T)
        sz = sizeof(T)
        sz == 8 && return TYPE_I64
        sz == 4 && return TYPE_I32
        sz == 2 && return TYPE_I32
        sz == 1 && return TYPE_I8
        sz == 0 && return TYPE_PTR  # singleton ghost types (Nothing, Union{})
        # 12-byte bitstype (e.g. RawGreenNode) — too large for a single register,
        # treat as TYPE_PTR
        return TYPE_PTR
    end
    # Abstract types that are always heap pointers (e.g. AbstractString, Exception)
    isabstracttype(T) && return TYPE_PTR
    # Union types: classify by arms. All-pointer → TYPE_PTR; all-same-scalar → that;
    # mixed (pointer+scalar) → TYPE_PTR (scalars are boxed into heap objects at phi edges).
    if T isa Union
        arms = _union_arms(T)
        arms_nonvoid = filter(!=(Nothing), arms)
        pointer_arms = filter(a -> a !== Nothing && is_ptr_type(a), arms_nonvoid)
        if length(pointer_arms) == length(arms_nonvoid)
            return TYPE_PTR  # all non-Nothing arms are heap pointers
        end
        # Check if all arms have the same Cranelift type
        arm_types = try cranelift_type.(arms) catch _; [] end
        if length(arm_types) == length(arms) && all(==(arm_types[1]), arm_types)
            return arm_types[1]
        end
        # Mixed pointer+scalar union: return as pointer (scalars boxed at phi)
        if !isempty(pointer_arms)
            return TYPE_PTR
        end
    end
    throw(CompileError("unsupported type $T"))
end

# Element byte-size for a Memory/MemoryRef/Ptr element type. `sizeof` THROWS for
# concrete-but-non-bitstype heap types (Symbol, String, any mutable struct) — they
# are all pointer-sized (8 bytes) when stored in a Memory/array. Use this anywhere
# an element type from a Memory{T}/MemoryRef{T}/Ptr{T} needs a byte width.
_elem_size(T) = T isa DataType && Base.isbitstype(T) ? sizeof(T) : 8

# Predicate: concrete immutable struct with heap fields that should be pointer-typed.
# Excludes GenericMemoryRef/GenericMemory (Core memory types managed via ref_tracking).
_is_heap_struct(T) = T isa DataType && isconcretetype(T) && !isbitstype(T) &&
                     !(T.name.name in (:GenericMemoryRef, :GenericMemory)) && !(T <: Ptr)

# Flatten a (potentially nested binary) Union into a tuple of leaf types.
_union_arms(T::Union) = (_union_arms(T.a)..., _union_arms(T.b)...)
_union_arms(T) = (T,)

function is_ptr_type(T)
    T isa DataType && !(T <: Ptr) && (
        Base.ismutabletype(T) || T === String || T <: Tuple || _is_heap_struct(T)
    )
end

# === BuilderCtx: tracks a Rust FunctionCtx for one Julia function ===

# In Julia structs, `Union{Nothing, T}` fields (where T is a pointer type) represent
# `nothing` as a tagged sentinel value. The sentinel cannot be a const because it
# depends on the runtime heap layout (changes every session). We compute it lazily
# at first use via get_nothing_tag().
struct _UnionProbe
    children::Union{Nothing, Vector{Int}}
end
const _NOTHING_TAG_CACHE = Ref{UInt64}(0)

function get_nothing_tag()
    tag = _NOTHING_TAG_CACHE[]
    tag != 0 && return tag
    try
        probe = _UnionProbe(nothing)
        r = Ref(probe)
        ref_ptr = convert(Ptr{Cvoid}, pointer_from_objref(r))
        offs = fieldoffset(_UnionProbe, :children)
        tag = unsafe_load(Ptr{UInt64}(ref_ptr + offs))
        _NOTHING_TAG_CACHE[] = tag
    catch e
        @warn "Failed to compute nothing tag, isnothing may be broken" exception = e
    end
    return tag
end

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
    # Cranelift type tracking: SSA value ID → Cranelift type enum.
    # Used by _harmonize_binop_type to resolve actual Cranelift widths.
    ssa_types::Dict{UInt32, UInt32}
    # Recursion support: name and MethodInstance of the function being compiled.
    # Used by emit_invoke to detect self-recursive :invoke calls.
    current_func_name::String
    current_mi::Union{Core.MethodInstance, Nothing}
    # Lazy foreign-import tracking: set of foreigncall names already declared
    imported_foreign::Set{String}
    # Module-level compilation: when non-nothing, emit_invoke enqueues unknown
    # callees into the worklist instead of emitting sentinel constants.
    # This mirrors WasmCodegen's ModuleCompiler worklist pattern.
    # Typed as Any to avoid forward-reference to ModuleCompiler (defined below).
    module_compiler::Any  # Union{ModuleCompiler, Nothing} in spirit
    # Targeted lowering for the generic kwcall sorter's emptiness check:
    # maps the SSA of a `Core._apply_iterate(iterate, tuple, vec)` whose result
    # type is a non-concrete (Vararg) Tuple → the underlying Vector value id.
    # `isa(result, Tuple{})` then lowers to `length(vec) == 0` (load vec+16).
    vararg_tuple_coll::Dict{Core.SSAValue, UInt32}
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
               Dict{Int, Tuple{UInt32, UInt32}}(),
               Dict{UInt32, UInt32}(),
               "", nothing,
               Set{String}(),
               nothing,
               Dict{Core.SSAValue, UInt32}())
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


# Mirrors WasmCodegen's ModuleCompiler + worklist pattern (compiler.jl lines 420-460,
# 2160-2189). Instead of compiling one function at a time, we compile the ENTIRE
# transitive call graph into one ObjectModule → one .o → one .so.
# Cross-function calls use the same declare_func_in_func mechanism as self-recursion.

mutable struct ModuleCompiler
    bc::BuilderCtx                    # shared BuilderCtx (one ObjectModule)
    interp::WasmInterp                # shared interpreter for inference
    worklist::Vector{Core.MethodInstance}  # pending functions (FIFO)
    status::Dict{Core.MethodInstance, Symbol}  # :pending / :compiled / :failed
    callee_names::Dict{Core.MethodInstance, String}  # MI → Cranelift func name
    compiled_count::Int               # counter for generating unique names
end

function ModuleCompiler(bc::BuilderCtx, interp::WasmInterp)
    ModuleCompiler(bc, interp,
                   Core.MethodInstance[],
                   Dict{Core.MethodInstance, Symbol}(),
                   Dict{Core.MethodInstance, String}(),
                   0)
end

# Enqueue a MethodInstance for compilation (idempotent).
# Returns the Cranelift function name assigned to this callee.
function request!(mc::ModuleCompiler, mi::Core.MethodInstance)
    if !haskey(mc.status, mi)
        mc.status[mi] = :pending
        push!(mc.worklist, mi)
        mc.compiled_count += 1
        mc.callee_names[mi] = "__compiled_fn_$(mc.compiled_count)_$(mi.def.name)"
    end
    return mc.callee_names[mi]
end

# Unwrap Core.Const from ir.argtypes elements (first element is always Core.Const(f)).
_ir_type(t) = t isa Core.Const ? typeof(t.val) : t
_ir_type(t::Type) = t

# === Main entry point ===


# === Module-level recursive compilation entry point ===
# Compiles the ENTIRE transitive call graph of `f` into one ObjectModule.
# Mirrors WasmCodegen's compile_wasm worklist loop (compiler.jl lines 2160-2189).

function emit_module_via_builder(interp::WasmInterp, f, argtypes::Type{<:Tuple};
                                  name::String="entry", output_path::String=tempname()*".o")
    # Specialize the entry-point function
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    matches === nothing && error("no method found for $f")
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())

    builder_lib = get_native_builder_lib()
    bc = BuilderCtx(builder_lib)
    _declare_imports(bc)

    mc = ModuleCompiler(bc, interp)
    # Wire the module compiler into the BuilderCtx so emit_invoke can find it
    bc.module_compiler = mc

    # Seed worklist with the entry function
    request!(mc, mi)
    mc.callee_names[mi] = String(name)

    # Worklist loop: compile every reachable callee
    while !isempty(mc.worklist)
        cur = popfirst!(mc.worklist)
        mc.status[cur] === :pending || continue
        try
            _compile_function_in_module!(mc, cur)
            mc.status[cur] = :compiled
        catch err
            if err isa InterruptException; rethrow(); end
            cur === mi && throw(err)  # entry must compile
            mc.status[cur] = :failed
        end
    end

    # Finalize: write all functions to one .o file
    finalize_ptr = Libdl.dlsym(bc.lib_handle, :builder_finalize)
    status = ccall(finalize_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}),
                   bc.builder_handle, output_path)
    status != 0 && error("Builder finalization failed")

    free_builder(bc)
    return output_path
end

# Compile a SINGLE MethodInstance into the shared Module.
# All functions share one BuilderCtx.
function _compile_function_in_module!(mc::ModuleCompiler, mi::Core.MethodInstance)
    bc = mc.bc
    func_name = mc.callee_names[mi]

    # Get optimized IR via the interpreter
    local ir, rettype
    try
        result = Base.code_ircode_by_type(mi.specTypes; world=mc.interp.world, interp=mc.interp)
        length(result) == 1 || throw(CompileError("expected unique match for $(mi.specTypes)"))
        ir, rettype = result[1]
    catch _
        throw(CompileError("Failed to get IR for $mi"))
    end

    if haskey(ENV, "NCG_DUMP_IR_FUNC") && occursin(ENV["NCG_DUMP_IR_FUNC"], func_name)
        println(stderr, "[ir-dump] === $func_name specTypes=$(mi.specTypes) argtypes=$(ir.argtypes) nstmts=$(length(ir.stmts)) ===")
        for si in 1:length(ir.stmts)
            println(stderr, "[ir $si] type=$(ir.stmts[si][:type]) :: $(repr(ir.stmts[si][:stmt]))")
        end
    end

    # Register argument values
    nparams = length(ir.argtypes) - 1
    for i in 1:nparams
        bc.arg_values[Core.Argument(i + 1)] = UInt32(i - 1)
    end
    bc.arg_values[Core.Argument(1)] = UInt32(0)

    # Add function to the shared ObjectModule
    ret_type_enum = try cranelift_type(rettype) catch _; TYPE_I64 end
    param_type_enums = UInt32[try cranelift_type(_ir_type(t)) catch _; TYPE_I64 end
                               for t in ir.argtypes[2:end]]

    add_func_ptr = Libdl.dlsym(bc.lib_handle, :builder_add_function)
    fctx_handle = ccall(add_func_ptr, Ptr{Cvoid},
                        (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                        bc.builder_handle, func_name, ret_type_enum,
                        param_type_enums, length(param_type_enums))
    fctx_handle == C_NULL && error("Failed to add function: $func_name")

    # Save/restore fctx_handle: each function gets its own FunctionCtx
    saved_fctx = bc.fctx_handle
    bc.fctx_handle = fctx_handle

    try
        # Declare self as callable (Linkage::Export — enables cross-function calls).
        self_decl_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_self_function)
        ccall(self_decl_ptr, Cint,
              (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
              bc.builder_handle, func_name, ret_type_enum,
              param_type_enums, length(param_type_enums))
        bc.current_func_name = func_name
        bc.current_mi = mi

        # Create at least N+1 blocks to cover all possible references.
        # Each IR statement index doubles as a potential block target.
        cfg = ir.cfg
        local nblocks = 2048
        for bi in 1:nblocks
            block_name = "block$(bi-1)"
            bc.blocks[bi] = block_name
            bi == 1 && continue
            add_block_ptr = Libdl.dlsym(bc.lib_handle, :function_add_block)
            ccall(add_block_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)
        end

        # Pre-scan phi nodes → block params
        add_bp = Libdl.dlsym(bc.lib_handle, :function_add_block_param)
        for (bi, block) in enumerate(cfg.blocks)
            block_name = bc.blocks[bi]
            for si in block.stmts
                e = ir.stmts[si][:stmt]
                if e isa Core.PhiNode
                    phi_type_enum = try cranelift_type(ir.stmts[si][:type]) catch _; TYPE_I64 end
                    param_id = ccall(add_bp, UInt32, (Ptr{Cvoid}, Ptr{UInt8}, UInt32),
                                    bc.fctx_handle, block_name, phi_type_enum)
                    bc.ssa_values[Core.SSAValue(si)] = param_id
                end
            end
        end

        # Emit each block
        for (bi, block) in enumerate(cfg.blocks)
            block_name = bc.blocks[bi]
            switch_ptr = Libdl.dlsym(bc.lib_handle, :function_switch_block)
            ccall(switch_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)

            had_terminator = false
            # terminator_emitted is set TRUE only when a terminator statement
            # (GotoNode/GotoIfNot/ReturnNode/throw-call) was SUCCESSFULLY emitted.
            # It is distinct from `had_terminator` (which is set whenever such a
            # statement is SEEN, even if its emit threw and was caught). The
            # fallback terminator below keys off `terminator_emitted` so that a
            # caught throw on a terminator statement still leaves the block with a
            # REAL terminator — otherwise the next switch_to_block trips Cranelift's
            # "you have to fill your block before switching" debug assertion.
            terminator_emitted = false
            for si in block.stmts
                had_terminator && break
                e = ir.stmts[si][:stmt]
                is_term_stmt = e isa Core.GotoNode || e isa Core.GotoIfNot || e isa Core.ReturnNode
                if !is_term_stmt && e isa Expr && e.head == :call && length(e.args) >= 1 &&
                   e.args[1] isa Core.GlobalRef &&
                   e.args[1].name in (:throw, :throw_methoderror,
                                     :throw_inexacterror, :throw_undef_if_null)
                    is_term_stmt = true
                end
                try
                    emit_instruction(bc, e, ir, si)
                    is_term_stmt && (terminator_emitted = true)
                catch ex
                    if !(ex isa CompileError || ex isa ErrorException)
                        # Rethrown exceptions abort the whole function's emission,
                        # which cascades into misleading "invalid block reference" /
                        # "no terminator" verifier errors (see CLAUDE.md). Log them
                        # when NCG_TRACE_RETHROW is set so the throw source is visible.
                        if haskey(ENV, "NCG_TRACE_RETHROW")
                            println(stderr, "[rethrow] $func_name bi=$bi si=$si stmt=$(typeof(e)) head=$(e isa Expr ? e.head : (e isa Core.GotoNode ? :GotoNode : e isa Core.GotoIfNot ? :GotoIfNot : e isa Core.ReturnNode ? :Return : "-")) EXC=$(typeof(ex)): $(ex)")
                            println(stderr, "[rethrow-stmt] $(repr(e))")
                            if haskey(ENV, "NCG_TRACE_BT")
                                foreach(f -> println(stderr, "   ", f), stacktrace(catch_backtrace())[1:min(end,10)])
                            end
                        end
                        rethrow()
                    end
                    # Tolerated throw (CompileError/ErrorException) — emit sentinel.
                    if haskey(ENV, "NCG_TRACE_SENTINEL")
                        println(stderr, "[sentinel] $func_name bi=$bi si=$si stmt=$(typeof(e)) head=$(e isa Expr ? e.head : "-") EXC=$(typeof(ex)): $(ex) :: $(repr(e)[1:min(end,160)])")
                        if haskey(ENV, "NCG_TRACE_BT") && (occursin("bitcast", string(ex)) || ex isa InexactError)
                            foreach(f -> println(stderr, "   ", f), stacktrace(catch_backtrace())[1:min(end,8)])
                        end
                    end
                    # Emit a correctly-typed zero sentinel on failure.
                    # The SSA's declared type (ir.stmts[si][:type]) determines the
                    # Cranelift value type — a Float32/64 SSA MUST get f32const/
                    # f64const, otherwise downstream float ops (fabs/fcmp) see an
                    # i64 and fail verification (parse_float_literal's strtof path).
                    bc.ssa_values[Core.SSAValue(si)] =
                        _undef_placeholder(bc, ir.stmts[si][:type])
                end
                if is_term_stmt
                    had_terminator = true
                end
            end

            # No real terminator emitted: if implicit fallthrough exists, emit jump.
            # Otherwise emit trap (dead-end block with no successors or multiple succs).
            # Keys off `terminator_emitted` (not `had_terminator`) so a terminator
            # statement whose emit threw still gets a fallback terminator here.
            if !terminator_emitted && length(block.succs) == 1
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
            elseif !terminator_emitted
                trap_ptr2 = Libdl.dlsym(bc.lib_handle, :block_add_trap)
                ccall(trap_ptr2, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
            end

            # Seal
            seal_ptr = Libdl.dlsym(bc.lib_handle, :function_seal_block)
            ccall(seal_ptr, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}),
                  bc.fctx_handle, block_name)
        end

        return nothing
    finally
        bc.fctx_handle = saved_fctx
        # Clear per-function state for the next function
        empty!(bc.ssa_values)
        empty!(bc.arg_values)
        empty!(bc.blocks)
        empty!(bc.ref_tracking)
        empty!(bc.ssa_pairs)
        empty!(bc.ssa_types)
        empty!(bc.vararg_tuple_coll)
        bc.current_func_name = ""
        bc.current_mi = nothing
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
            # sizeof(T) for a type parameter — compute at compile time if possible
            if length(args) >= 1
                local T = nothing
                if args[1] isa QuoteNode; T = args[1].value
                elseif args[1] isa Core.Const; T = args[1].val
                elseif args[1] isa DataType; T = args[1]
                end
                if T isa DataType
                    return emit_constant(bc, Int64(try sizeof(T) catch; 8 end))
                elseif T isa UnionAll || T isa Union
                    return emit_constant(bc, Int64(8))  # pointer-width fallback
                end
            end
            # sizeof(s::String) == ncodeunits(s) — emit load from ptr+0
            result_id = emit_string_ncodeunits(bc, args, ir)
        elseif f === Core.memoryrefunset!
            # memoryrefunset!(ref, ordering, boundscheck) — store zero at ref for GC safety
            result_id = emit_memoryrefunset(bc, args, ir)
        elseif f === Core.memoryrefnew
            # memoryrefnew(mem_or_ref, idx, boundscheck) → MemoryRef, OR
            # memoryrefnew(mem) → MemoryRef from raw Memory (1-arg form).
            # Dispatched here (not in emit_intrinsic) because Core.memoryrefnew
            # is a singleton intrinsic of its own type, NOT a Core.IntrinsicFunction
            # — same situation as Core.memoryrefunset! above. jl_intrinsic_name
            # returns "invalid" for it, so the fn_sym ladder cannot match.
            result_id = length(args) >= 2 ? emit_memoryrefnew(bc, args, ir, stmt_idx) :
                        emit_memoryref_from_mem(bc, args, ir, stmt_idx)
        elseif f === Core.memoryrefget
            # memoryrefget(ref, ordering, boundscheck) → T
            result_id = emit_memoryrefget(bc, args, ir)
        elseif f === Core.memoryrefset!
            # memoryrefset!(ref, val, ordering, boundscheck) → T
            result_id = emit_memoryrefset(bc, args, ir)
        elseif f === Core.memoryrefoffset
            # memoryrefoffset(ref) → Int64 (1-based element index). For a fresh
            # MemoryRef from a Vector's :ref field, byte_offset==0 → result==1.
            # General: byte_offset / elem_size + 1.
            memref_val = args[1]
            tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
                      bc.ref_tracking[memref_val] : nothing
            if tracked !== nothing
                _, byte_off, memref_T = tracked
                elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
                         memref_T.parameters[2] : Int64
                elem_index = Int64(byte_off ÷ _elem_size(elem_T)) + Int64(1)
                result_id = emit_constant(bc, elem_index)
            else
                # Untracked / fresh ref: offset is 1 (mirrors the GlobalRef handler).
                result_id = emit_constant(bc, Int64(1))
            end
        elseif f === Core.isa
            # isa(x, Type) — type check. Currently only handles isa(x, Nothing)
            # on pointer values (icmp eq ptr_val, 0).
            result_id = emit_isa(bc, args, ir)
        elseif f === Core.ifelse
            # ifelse(cond, a, b) → Cranelift select(cond, a, b)
            result_id = emit_select(bc, args, ir)
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
    elseif e isa Expr && (e.head == :gc_preserve_begin || e.head == :gc_preserve_end)
        # GC-preserve markers: no-op at the Cranelift level. Emit a placeholder
        # with the SSA type's Cranelift representation so downstream references work.
        stmt_type = ir.stmts[stmt_idx][:type]
        if stmt_type === Nothing || (stmt_type isa Core.Const && stmt_type.val === nothing)
            result_id = emit_constant(bc, Int64(0))
        else
            result_id = resolve_operand(bc, e.args[1], ir)
        end
        bc.ssa_values[Core.SSAValue(stmt_idx)] = result_id
    elseif e isa Expr && e.head == :foreigncall
        # Foreigncall: C function call via ccall. Map known simple functions to
        # inline operations; unrecognized functions resolve via import.
        result_id = emit_foreigncall(bc, e, ir, stmt_idx)
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
                # Return `nothing` (singleton ghost type) — emit null pointer
                # (iconst 0, TYPE_I64) to match function signature typed as
                # TYPE_PTR (Cranelift I64). cranelift_type(Nothing) returns
                # TYPE_PTR via the sizeof==0 fallback, so a bare `nothing`
                # literal via `ReturnNode` would hit a void-return which emits
                # return_(&[]), but the signature expects an I64 value →
                # verifier error. This applies regardless of the statement
                # level type (it may be `Any` even when the function's
                # overall rettype is `Nothing`). Create a zero I64 constant
                # instead; the bridge (ccall with Cvoid return) discards the
                # return value.
                iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
                zero_id = ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                                bc.fctx_handle, Int64(0), TYPE_I64)
                return_ptr = Libdl.dlsym(bc.lib_handle, :block_add_return)
                ccall(return_ptr, Cvoid, (Ptr{Cvoid}, UInt32),
                      bc.fctx_handle, zero_id)
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
            # succs[1] is typically the explicit dest, succs[2] the fallthrough.
            # But sometimes dest_bi == succs[2] — in that case use succs[1] instead.
            if succs[2] == dest_bi
                fallthrough_bi = succs[1]
            else
                fallthrough_bi = succs[2]
            end
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
                    if isassigned(e.values, j)
                        push!(args, resolve_operand(bc, e.values[j], ir))
                    else
                        # The phi value is unassigned (#undef) on this edge — Julia
                        # leaves the slot empty when the variable is unreachable
                        # along that predecessor path (e.g. loop-carried Bool flags
                        # on dead escape edges). Pass a zero placeholder of the
                        # phi's type so the jump arg count matches the block param
                        # count; the value is never used along this path. Without
                        # this guard, e.values[j] throws UndefRefError, aborting
                        # the whole function's emission.
                        push!(args, _undef_placeholder(bc, ir.stmts[si][:type]))
                    end
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
        return resolve_operand(bc, getglobal(val.mod, val.name), ir)
    elseif val isa Core.QuoteNode
        # QuoteNode wraps a value; unwrap and resolve
        return resolve_operand(bc, val.value, ir)
    elseif isa(val, Number)
        # Create constant each time (caching causes cross-block dominance issues)
        return emit_constant(bc, val)
    elseif val === nothing || isghost(typeof(val))
        # nothing in union fields has a specific tag (0x103 in Julia v1.x), not 0x0.
        # Use get_nothing_tag() so comparisons with union-field values work correctly.
        # The tag is a tagged sentinel specific to the current Julia session's heap.
        nothing_tag = get_nothing_tag()
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                   bc.fctx_handle, Int64(nothing_tag), TYPE_PTR)
    elseif val isa Bool
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                   bc.fctx_handle, Int64(val ? 1 : 0), TYPE_I32)
    elseif val isa Tuple
        # Handle tuple constants by emitting tuple creation
        args = [Core.Const(v) for v in val]
        return emit_core_tuple(bc, args, ir)
    elseif val isa AbstractString || val isa Symbol
        # String/Symbol literal: emit its object pointer as a constant. The
        # value is already a real Julia object; it round-trips back via
        # unsafe_pointer_to_objref on return.
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                   bc.fctx_handle, Int64(reinterpret(UInt64, pointer_from_objref(val))),
                     TYPE_PTR)
    elseif val === nothing
        # nothing → null pointer constant (0)
        return emit_constant(bc, Int64(0))
    elseif val isa Ptr
        # Raw pointer constant — emit as i64
        return emit_constant(bc, Int64(reinterpret(UInt64, val)))
    elseif Base.isprimitivetype(typeof(val))
        # Primitive type (e.g. Kind(16-bit), Char(32-bit), Int128(128-bit)).
        # Pass the unsigned bit pattern to emit_constant (which reinterprets to
        # Int64 bits) — NOT Int32(raw)/Int64(raw), which throw InexactError for
        # high-bit-set values (e.g. Char > 0x7fffffff, or UInt-primitive maxima).
        sz = sizeof(val)
        if sz == 2
            return emit_constant(bc, reinterpret(UInt16, val))
        elseif sz == 4
            return emit_constant(bc, reinterpret(UInt32, val))
        elseif sz == 8
            return emit_constant(bc, reinterpret(UInt64, val))
        else
            return emit_constant(bc, Int64(0))  # Int128 etc. — lossy fallback (rare)
        end
    elseif isbitstype(typeof(val))
        # Bitstype structs (e.g. SyntaxHead, RawGreenNode) — reinterpret as UInt
        sz = sizeof(val)
        local raw::UInt64
        if sz == 8
            raw = reinterpret(UInt64, val)
        elseif sz == 4
            raw = UInt64(reinterpret(UInt32, val))
        elseif sz == 2
            raw = UInt64(reinterpret(UInt16, val))
        elseif sz == 1
            raw = UInt64(reinterpret(UInt8, val))
        else
            raw = UInt64(0)
        end
        return emit_constant(bc, sz <= 4 ? UInt32(raw) : raw)
    elseif val isa VersionNumber
        # Immutable struct with pointer fields — wrap in Ref for pointer_from_objref
        return emit_constant(bc, Int64(reinterpret(UInt64, pointer_from_objref(Ref(val)))))
    elseif val isa DataType || val isa UnionAll || val isa Union
        # Type values — emit as pointer constant
        return emit_constant(bc, Int64(reinterpret(UInt64, pointer_from_objref(val))))
    else
        # Any other heap object (module-constant Vector/Array, String, Symbol,
        # struct instance, …) — emit as its pointer so downstream getfield
        # (:ref/:size) and field-offset loads work. pointer_from_objref is valid
        # for every Julia object reaching here (Number/Ptr/primitive/bitstype/
        # Type/nothing are all handled above).
        return emit_constant(bc, Int64(reinterpret(UInt64, pointer_from_objref(val))))
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
        sz = sizeof(val)
        ty = sz <= 4 ? TYPE_I32 : TYPE_I64
        # Extract the bit pattern via reinterpret (NOT checked Int64(val), which
        # throws InexactError for negative or >typemax unsigned values). The iconst
        # FFI takes an Int64 immediate that encodes the raw bits regardless of sign.
        ubits = sz == 16 ? UInt64(reinterpret(UInt128, val) & ((UInt128(1) << 64) - 1)) :  # Int128/UInt128 low 64 bits (UInt128 is checked; mask is not)
                sz == 8 ? reinterpret(UInt64, val) :
                sz == 4 ? UInt64(reinterpret(UInt32, val)) :
                sz == 2 ? UInt64(reinterpret(UInt16, val)) :
                           UInt64(reinterpret(UInt8, val))
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle, reinterpret(Int64, ubits), ty)
    else
        # Any other value (Symbol, String, Vector, struct instance, …) is a heap
        # object — emit its pointer as an i64 constant.
        iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
        return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                     bc.fctx_handle,
                     reinterpret(Int64, reinterpret(UInt64, pointer_from_objref(val))),
                     TYPE_PTR)
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
    fn_sym == :sgt_int && return emit_icmp(bc, ICMP_SGT, args, ir)
    fn_sym == :sge_int && return emit_icmp(bc, ICMP_SGE, args, ir)
    fn_sym == :ugt_int && return emit_icmp(bc, ICMP_UGT, args, ir)
    fn_sym == :uge_int && return emit_icmp(bc, ICMP_UGE, args, ir)

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
    fn_sym == :gt_float && return emit_fcmp(bc, FCMP_GT, args, ir)
    fn_sym == :ge_float && return emit_fcmp(bc, FCMP_GE, args, ir)

    # neg_int = 0 - x
    fn_sym == :neg_int && return emit_neg_int(bc, args, ir)
    # not_int = x ⊻ -1
    fn_sym == :not_int && return emit_not_int(bc, args, ir)

    # Bit-count / byte-swap unops (same width in/out; Cranelift infers width)
    fn_sym == :ctlz_int && return emit_clz(bc, args, ir)
    fn_sym == :cttz_int && return emit_ctz(bc, args, ir)
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
    # Type-harmonize: if operands have different Cranelift register widths
    # (e.g. Ptr{I64} + UInt8(I32) in pointer arithmetic), extend the narrower
    # one to match. Without this, Cranelift's verifier rejects e.g. isub.i64
    # with an i32 second operand.
    lhs = _harmonize_binop_type(bc, lhs, args[1], rhs, args[2], ir)
    rhs = _harmonize_binop_type(bc, rhs, args[2], lhs, args[1], ir)
    fn_ptr = Libdl.dlsym(bc.lib_handle, ffi_sym)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, lhs, rhs)
end

# If `self_val` has a narrower Cranelift type than `other_val`, uextend it.
# Uses cranelift_type enum values: I8/I16/I32 are narrower than I64/PTR.
_is_narrow_ct(ct) = ct == TYPE_I8 || ct == TYPE_I16 || ct == TYPE_I32
_is_wide_ct(ct)   = ct == TYPE_I64 || ct == TYPE_PTR

function _harmonize_binop_type(bc, self_id, self_arg, other_id, other_arg, ir)
    # Use actual Cranelift types (queried from Rust) instead of Julia types.
    # Julia types may not match Cranelift widths due to narrowing/widening.
    get_ct = Libdl.dlsym(bc.lib_handle, :block_get_ssa_type)
    ct_self = ccall(get_ct, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, self_id)
    ct_other = ccall(get_ct, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, other_id)
    if _is_narrow_ct(ct_self) && _is_wide_ct(ct_other)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, self_id, ct_other)
    end
    # If self is wide and other is narrow, the other operand's call to this
    # function will extend it.  We just return self unchanged.
    return self_id
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
    # Type-harmonize like emit_binop
    lhs = _harmonize_binop_type(bc, lhs, args[1], rhs, args[2], ir)
    rhs = _harmonize_binop_type(bc, rhs, args[2], lhs, args[1], ir)
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
    to_T = _unwrap_type(args[1])
    val = resolve_operand(bc, args[2], ir)
    to_type_enum = cranelift_type(to_T)
    # Skip no-op conversions using actual Cranelift types
    if ffi_sym in (:block_add_uextend, :block_add_sextend, :block_add_ireduce)
        get_ct = Libdl.dlsym(bc.lib_handle, :block_get_ssa_type)
        from_ct = ccall(get_ct, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, val)
        if from_ct == to_type_enum
            return val  # source already at target width — skip
        end
    end
    fn_ptr = Libdl.dlsym(bc.lib_handle, ffi_sym)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, val, to_type_enum)
end

function emit_trunc(bc::BuilderCtx, args, ir)
    length(args) < 2 && error("trunc needs 2 args")
    to_T = _unwrap_type(args[1])
    val = resolve_operand(bc, args[2], ir)
    sz = sizeof(to_T)
    to_type_enum = sz == 1 ? TYPE_I8 : sz == 2 ? TYPE_I16 : cranelift_type(to_T)
    # Skip no-op trunc
    get_ct = Libdl.dlsym(bc.lib_handle, :block_get_ssa_type)
    from_ct = ccall(get_ct, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, val)
    if from_ct == to_type_enum
        return val
    end
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_ireduce)
    reduced = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, val, to_type_enum)
    # If the target is sub-word, extend back to i32 to match storage convention.
    # Sub-word values live in i32 registers; ireduce narrows to i8/i16, which
    # must be widened back so the result type matches the function signature.
    if sz < 4
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, reduced, TYPE_I32)
    end
    return reduced
end

# neg_int: 0 - x
function emit_neg_int(bc::BuilderCtx, args, ir)
    val = resolve_operand(bc, args[1], ir)
    T = get_operand_type(args[1], ir)
    T = T isa Core.Const ? T.val : T
    sz = sizeof(T)
    zero_id = emit_constant(bc, sz >= 4 ? Int64(0) : Int32(0))
    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
    return ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                 bc.fctx_handle, zero_id, val)
end

# not_int: Bool → logical NOT (icmp_eq); integer → bitwise NOT (xor + mask)
function emit_not_int(bc::BuilderCtx, args, ir)
    T = get_operand_type(args[1], ir)
    T = T isa Core.Const ? T.val : T
    val = resolve_operand(bc, args[1], ir)
    if T === Bool
        # Bool: logical NOT = icmp_eq(val, 0), then uextend to i32
        zero = emit_constant(bc, Int32(0))
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_EQ, val, zero)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, TYPE_I32)
    else
        sz = sizeof(T)
        # Use the same width as the operand for the -1 sentinel and mask
        if sz >= 4
            ones_id = emit_constant(bc, Int64(-1))
        else
            ones_id = emit_constant(bc, Int32(-1))
        end
        xor_ptr = Libdl.dlsym(bc.lib_handle, :block_add_bxor)
        xored = ccall(xor_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                      bc.fctx_handle, val, ones_id)
        if sz < 4
            mask = (1 << (8 * sz)) - 1  # e.g. 0xFFFF for UInt16
            mask_id = emit_constant(bc, Int32(mask))
            band_ptr = Libdl.dlsym(bc.lib_handle, :block_add_band)
            return ccall(band_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                         bc.fctx_handle, xored, mask_id)
        end
        return xored
    end
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

# emit_clz: count-leading-zeros with sub-word correction.
# Cranelift clz counts across the full register width (i32 for sub-word types
# stored as i32). For types narrower than 32 bits, the extra leading zeros
# above the logical width inflate the count → subtract padding bits.
# ctz and ctpop are correct as-is for zero-extended values (trailing zeros
# and set-bit count don't change), so they stay with emit_unop.
function emit_clz(bc::BuilderCtx, args, ir)
    val = resolve_operand(bc, args[1], ir)
    T = get_operand_type(args[1], ir)
    T = T isa Core.Const ? T.val : T
    sz = sizeof(T)

    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_clz)
    result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, val)

    if sz < 4
        correction = 32 - 8 * sz
        correction_id = emit_constant(bc, Int32(correction))
        sub_ptr = Libdl.dlsym(bc.lib_handle, :block_add_isub)
        return ccall(sub_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, correction_id)
    end
    return result
end

# emit_ctz: count-trailing-zeros with sub-word zero-input correction.
# Cranelift ctz on zero returns the full register width (32 for i32 storage).
# For sub-word types, we clamp: if result > logical_width, return logical_width.
function emit_ctz(bc::BuilderCtx, args, ir)
    val = resolve_operand(bc, args[1], ir)
    T = get_operand_type(args[1], ir)
    T = T isa Core.Const ? T.val : T
    sz = sizeof(T)

    fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_ctz)
    result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, val)

    if sz < 4
        logw = 8 * sz
        # If result > logw (zero input → Cranelift returns 32), clamp to logw
        over_id = emit_constant(bc, Int32(logw))
        icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        is_over = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_UGT, result, over_id)
        sel_ptr = Libdl.dlsym(bc.lib_handle, :block_add_select)
        return ccall(sel_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                    bc.fctx_handle, is_over, over_id, result)
    end
    return result
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

# Bypass a Core.kwcall sorter whose kwargs NamedTuple is a compile-time constant
# but which has RUNTIME positional args (e.g. peek_token(ps, 1; skip_newlines=true)).
# Emits a cross-call to func's CORE method (the non-kwarg body) with
# (positional args…, kwarg values…). Returns the call's result id, or nothing if
# the core method can't be resolved/compiled. kwargs are in declaration order
# (literal NamedTuples preserve it), matching the core method's trailing params.
function _emit_kwcall_core_call(bc::BuilderCtx, func_val, kw_nt, positional, ir)
    mc = bc.module_compiler
    # Core method signature tuple: (typeof(func), positional_types..., kwarg_types...)
    local pos_types
    try
        pos_types = Type[let t = get_operand_type(p, ir); t isa Core.Const ? typeof(t.val) : t; end
                         for p in positional]
    catch _
        return nothing
    end
    kw_types = Type[typeof(v) for v in values(kw_nt)]
    core_tt = try; Tuple{typeof(func_val), pos_types..., kw_types...}; catch _; return nothing; end
    matches = try; Base._methods_by_ftype(core_tt, -1, mc.interp.world); catch _; nothing; end
    (matches === nothing || isempty(matches)) && return nothing
    core_mi = try; CC.specialize_method(matches[1].method, core_tt, Core.svec()); catch _; nothing; end
    core_mi === nothing && return nothing
    # Resolve the core callee's return/param types + CFG sanity (mirror the
    # generic cross-call guard — skip if succs fall outside cfg.blocks).
    local callee_rt_enum, callee_param_types
    got = false
    try
        cr = Base.code_ircode_by_type(core_mi.specTypes; world=mc.interp.world, interp=mc.interp)
        if length(cr) == 1
            cir, cret = cr[1]
            nb = length(cir.cfg.blocks); ok = true
            for blk in cir.cfg.blocks
                for s in blk.succs
                    if s < 1 || s > nb; ok = false; break; end
                end; ok || break
            end
            if ok
                callee_rt_enum = cranelift_type(cret)
                callee_param_types = UInt32[cranelift_type(_ir_type(t)) for t in cir.argtypes[2:end]]
                got = true
            end
        end
    catch _
    end
    got || return nothing
    callee_name = request!(mc, core_mi)
    decl_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_self_function)
    ccall(decl_ptr, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
          bc.builder_handle, callee_name, callee_rt_enum,
          callee_param_types, length(callee_param_types))
    # Args: runtime positional args, then the constant kwarg values (decl order).
    arg_ids = UInt32[resolve_operand(bc, p, ir) for p in positional]
    for v in values(kw_nt)
        push!(arg_ids, emit_constant(bc, v))
    end
    call_ptr = Libdl.dlsym(bc.lib_handle, :block_add_call)
    return ccall(call_ptr, UInt32, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Ptr{UInt32}, Csize_t),
                 bc.fctx_handle, bc.builder_handle, callee_name, arg_ids, length(arg_ids))
end

function emit_invoke(bc::BuilderCtx, invoke_target, f, args, ir, stmt_idx)
    if haskey(ENV, "NCG_TRACE_INVOKE")
        iskw = (f === Core.kwcall) || (f isa QuoteNode && f.value === Core.kwcall)
        println(stderr, "[invoke] $(bc.current_func_name) f=$(repr(f)) typeof=$(typeof(f)) iskwcall=$iskw nargs=$(length(args))")
    end
    # Check for self-recursive call: if the invoke target's MethodInstance
    # matches the function we're currently compiling, emit a call to our
    # self-import (declared via builder_declare_self_function).
    if invoke_target isa Core.CodeInstance
        callee_mi = invoke_target.def  # CodeInstance → MethodInstance
    elseif invoke_target isa Core.MethodInstance
        callee_mi = invoke_target
    else
        error("Unknown invoke target type: $(typeof(invoke_target))")
    end
    if bc.current_mi !== nothing && callee_mi == bc.current_mi
        # Self-recursive call — resolve args and emit call to self-import
        return emit_call_import(bc, bc.current_func_name, args, ir)
    end

    # Core.kwcall(kwargs_nt, func) — keyword-argument dispatch. Detect by the
    # CALLEE FUNCTION being Core.kwcall (NOT by method.name — the sorter MI's
    # method.name is the sorted function's name, e.g. :open_flags). The callee MI
    # is the generic kwcall sorter (84+ stmts, needs runtime _apply_iterate /
    # Vararg-tuple support). When the kwargs NamedTuple is a compile-time constant
    # at the CALLER (literal kwargs like open_flags(; read=true, …)), evaluate the
    # kwcall in host Julia now and emit the constant result — sidestepping the
    # sorter entirely (so it is never invoked at runtime and its unsupported body
    # doesn't matter). args = [kwargs_nt, func]. NOTE: the callee `f` arrives as
    # a GlobalRef / QuoteNode wrapping Core.kwcall (IR renders it as
    # `:(Core.kwcall)`), so unwrap before comparing.
    kw_callee = if f isa QuoteNode; f.value
                 elseif f isa Core.GlobalRef; getglobal(f.mod, f.name)
                 elseif f isa Core.Const; f.val
                 else f end
    if kw_callee === Core.kwcall && length(args) >= 2
        kw_nt = _const_value(args[1], ir)
        func_val = _const_value(args[2], ir)
        if haskey(ENV, "NCG_TRACE_KW")
            println(stderr, "[kw] caller=$(bc.current_func_name) args1=$(repr(args[1])) args2=$(repr(args[2])) kw_nt=$(kw_nt isa _NotConst ? "NOTCONST" : typeof(kw_nt)) func=$(func_val isa _NotConst ? "NOTCONST" : func_val)")
        end
        if !(kw_nt isa _NotConst) && !(func_val isa _NotConst) && kw_nt isa NamedTuple && func_val isa Function
            positional = args[3:end]   # runtime positional args (after [kwargs_nt, func])
            if isempty(positional)
                # Fully-constant kwcall: eval the whole call in host Julia.
                result = try; func_val(; kw_nt...); catch _; _NotConst() end
                if !(result isa _NotConst)
                    return emit_constant(bc, result)
                end
            elseif bc.module_compiler !== nothing
                # Constant kwargs + RUNTIME positional args (e.g.
                # peek_token(ps, 1; skip_newlines=true, …)). Bypass the sorter
                # by calling func's CORE method with (positional…, kwarg_values…).
                # Literal-kwarg NamedTuples are in declaration order = core param
                # order, so values(kw_nt) lines up with the trailing params.
                result_id = _emit_kwcall_core_call(bc, func_val, kw_nt, positional, ir)
                result_id !== nothing && return result_id
            end
        end
        # else: non-constant kwargs — fall through to compile the sorter (currently
        # degrades on _apply_iterate; runtime kwarg support is a future feature).
    end

    # invoke_target can be CodeInstance or MethodInstance
    if invoke_target isa Core.CodeInstance
        method = invoke_target.def.def     # CodeInstance → MethodInstance → Method
    elseif invoke_target isa Core.MethodInstance
        method = invoke_target.def          # MethodInstance → Method
    else
        error("Unknown invoke target type: $(typeof(invoke_target))")
    end
    fn_name = method.name

    # Core.kwcall(kwargs_nt, func) — keyword-argument dispatch. The callee MI is
    # the generic kwcall SORTER (84+ stmts, needs runtime _apply_iterate / Vararg-
    # tuple support — a future feature). But when the kwargs NamedTuple is a
    # compile-time constant at the CALLER (the common case: literal kwargs like
    # open_flags(; read=true, …)), we can evaluate the kwcall in host Julia right
    # now and emit the constant result — sidestepping the sorter entirely (so the
    # sorter is never invoked at runtime and its unsupported body doesn't matter).

    # String operations — emit loads from known Julia String layout:
    #   ptr = pointer_from_objref(s) points to:
    #     offset 0: size_t length (Int64)
    #     offset 8: char data[] (inline, null-terminated)
    if fn_name == :ncodeunits && length(args) >= 1
        return emit_string_ncodeunits(bc, args, ir)
    elseif fn_name == :codeunit && length(args) >= 2
        return emit_string_codeunit(bc, args, ir)
    elseif fn_name == :sizeof && length(args) >= 1
        # sizeof(T) for a type argument — compute at compile time
        local sz_T = nothing
        if args[1] isa QuoteNode; sz_T = args[1].value
        elseif args[1] isa Core.Const; sz_T = args[1].val
        elseif args[1] isa DataType; sz_T = args[1]
        end
        if sz_T isa DataType
            return emit_constant(bc, Int64(try sizeof(sz_T) catch; 8 end))
        elseif sz_T isa UnionAll || sz_T isa Union
            return emit_constant(bc, Int64(8))
        end
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
            elem_size = _elem_size(elem_T)
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

    # isnothing(x) → tagged null pointer check (icmp_eq val, nothing_tag)
    # In union fields Union{Nothing, T}, nothing is represented as a tagged value,
    # not a raw null pointer (0x0).
    if fn_name == :isnothing && length(args) >= 1
        val = resolve_operand(bc, args[1], ir)
        nothing_tag = get_nothing_tag()
        zero = emit_constant(bc, Int64(nothing_tag))
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_EQ, val, zero)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, TYPE_I32)
    end

    # haschildren(x) → children(x) !== nothing (deprecated alias for !is_leaf)
    if fn_name == :haschildren && length(args) >= 1
        val = resolve_operand(bc, args[1], ir)
        T = get_operand_type(args[1], ir)
        T = T isa Core.Const ? T.val : T
        offset = fieldoffset(T, :children)
        load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
        children_ptr = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                             bc.fctx_handle, val, Int32(offset), TYPE_PTR)
        nothing_tag = get_nothing_tag()
        tag_id = emit_constant(bc, Int64(nothing_tag))
        icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_NE, children_ptr, tag_id)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, TYPE_I32)
    end

    # untokenize(Kind) → Union{String, Nothing} — resolve at compile time
    if fn_name == :untokenize && length(args) >= 1
        op = args[1]
        local kind_val, str
        if op isa Core.SSAValue
            kind_val = try
                stmt = ir.stmts[op.id][:stmt]
                if stmt isa Expr && stmt.head == :call
                    f = stmt.args[1]
                    if f isa Core.GlobalRef && f.name === :Kind && length(stmt.args) >= 2
                        arg2 = stmt.args[2]; arg2 isa Core.Const && getglobal(f.mod, :Kind)(arg2.val)
                    else nothing end
                else nothing end
            catch _; nothing end
        elseif op isa Core.Const; kind_val = op.val
        end
        if kind_val !== nothing
            str = getglobal(f.mod, :untokenize)(kind_val)
            if str === nothing
                return emit_constant(bc, Int64(get_nothing_tag()))
            end
            iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
            return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                         bc.fctx_handle, Int64(reinterpret(UInt64, pointer_from_objref(str))), TYPE_PTR)
        end
    end

    # Unknown invoke — two paths depending on compilation mode:
    # 1. Recursive (bc.module_compiler set): enqueue callee and emit cross-function call.
    #    Mirrors WasmCodegen's request! + CallTarget pattern (compiler.jl line 1451-1452).
    # 2. Fallback: emit sentinel constant.
    mc = bc.module_compiler
    if mc !== nothing && callee_mi isa Core.MethodInstance
        # Try to resolve the callee's IR. If cranelift_type throws (e.g. Union{}
        # return in dead error paths), fall through to the sentinel constant.
        local callee_rt_enum, callee_param_types
        local got_ir = false
        try
            callee_result = Base.code_ircode_by_type(callee_mi.specTypes;
                                                      world=mc.interp.world, interp=mc.interp)
            if length(callee_result) == 1
                callee_ir, callee_rettype = callee_result[1]
                # CFG sanity: skip cross-call if callee has successor blocks
                # outside cfg.blocks (causes "invalid block reference" verifier error)
                local cfg_ok = true
                local nblocks = length(callee_ir.cfg.blocks)
                for blk in callee_ir.cfg.blocks
                    for s in blk.succs
                        if s < 1 || s > nblocks; cfg_ok = false; break; end
                    end
                    cfg_ok || break
                end
                if cfg_ok
                    callee_rt_enum = cranelift_type(callee_rettype)
                    callee_param_types = UInt32[cranelift_type(_ir_type(t))
                                                 for t in callee_ir.argtypes[2:end]]
                    got_ir = true
                end
            end
        catch _
        end
        if got_ir
            callee_name = request!(mc, callee_mi)
            # Pre-declare the callee in the ObjectModule so cross-calls can resolve it
            decl_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_self_function)
            ccall(decl_ptr, Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                  bc.builder_handle, callee_name, callee_rt_enum,
                  callee_param_types, length(callee_param_types))
            # Emit args and cross-function call
            arg_ids = UInt32[resolve_operand(bc, a, ir) for a in args]
            call_ptr = Libdl.dlsym(bc.lib_handle, :block_add_call)
            return ccall(call_ptr, UInt32,
                         (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Ptr{UInt32}, Csize_t),
                         bc.fctx_handle, bc.builder_handle, callee_name, arg_ids, length(arg_ids))
        end
    end
    # Fallback: emit sentinel constant (single-function mode or failed resolution)
    local sentinel_ty
    try
        inferred = ir.stmts[stmt_idx][:type]
        sentinel_ty = cranelift_type(inferred)
    catch _
        sentinel_ty = TYPE_I64
    end
    iconst_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iconst)
    return ccall(iconst_ptr, UInt32, (Ptr{Cvoid}, Int64, UInt32),
                 bc.fctx_handle, Int64(0), sentinel_ty)
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
    if fn == :sgt_int ; return emit_icmp(bc, ICMP_SGT, args, ir) end
    if fn == :sge_int ; return emit_icmp(bc, ICMP_SGE, args, ir) end
    if fn == :ugt_int ; return emit_icmp(bc, ICMP_UGT, args, ir) end
    if fn == :uge_int ; return emit_icmp(bc, ICMP_UGE, args, ir) end

    # === Integer bitwise (may also be used as not_int) ===
    if fn == :neg_int || fn == :neg_int ; return emit_neg_int(bc, args, ir) end
    if fn == :not_int ; return emit_not_int(bc, args, ir) end
    if fn == :and_int || fn == :& ; return emit_binop(bc, :block_add_band, args, ir) end
    if fn == :or_int || fn == :|  ; return emit_binop(bc, :block_add_bor, args, ir) end
    if fn == :xor_int ; return emit_binop(bc, :block_add_bxor, args, ir) end
    if fn == :shl_int ; return emit_binop(bc, :block_add_ishl, args, ir) end
    if fn == :add_ptr && length(args) >= 2 ; return emit_binop(bc, :block_add_iadd, args, ir) end
    if fn == :sub_ptr && length(args) >= 2 ; return emit_binop(bc, :block_add_isub, args, ir) end
    if fn == :lshr_int ; return emit_binop(bc, :block_add_ushr, args, ir) end
    if fn == :ashr_int ; return emit_binop(bc, :block_add_sshr, args, ir) end
    # Bit-count / byte-swap (full-width correct; sub-word needs renormalization)
    if fn == :ctlz_int ; return emit_clz(bc, args, ir) end
    if fn == :cttz_int ; return emit_ctz(bc, args, ir) end
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
    if fn == :gt_float ; return emit_fcmp(bc, FCMP_GT, args, ir) end
    if fn == :ge_float ; return emit_fcmp(bc, FCMP_GE, args, ir) end

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

    # === Type introspection (nfields, etc.) ===
    if fn == :nfields && length(args) >= 1
        # nfields(T) returns the number of fields in type T.
        # Resolve at compile time if the type is a constant.
        a1 = args[1]
        local nf::Int
        if a1 isa QuoteNode
            nf = fieldcount(a1.value)
        elseif a1 isa Core.Const
            nf = fieldcount(a1.val)
        elseif a1 isa DataType
            nf = fieldcount(a1)
        else
            # Dynamic type — emit 0 as fallback
            nf = 0
        end
        return emit_constant(bc, Int32(Int(nf)))
    end

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
            elem_index = Int64(byte_off ÷ _elem_size(elem_T)) + Int64(1)
            return emit_constant(bc, elem_index)
        end
        # Fallback: return constant 1 (valid for all non-sliced arrays)
        return emit_constant(bc, Int64(1))
    end
    if fn == :_apply_iterate
        # Core._apply_iterate(iterate, g, coll) = g(iterate(coll)...) — the kwarg
        # / varargs splat lowering. When `coll` (args[3]) is a compile-time
        # constant (e.g. constant kwargs to open_flags(; read=true, …)), evaluate
        # it at compile time and emit the resulting tuple. Dynamic collections
        # (runtime-built vectors) are not yet supported → CompileError (tolerated).
        return emit_apply_iterate(bc, args, ir, stmt_idx)
    end
    if fn == :throw
        # Base.throw(...) — always Union{}-typed (never returns). Emit trap.
        trap_ptr = Libdl.dlsym(bc.lib_handle, :block_add_trap)
        ccall(trap_ptr, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
        return nothing
    end
    # Dead-error-path sentinels: these Core globals appear in bounds-error /
    # method-error paths that never execute on correct inputs. Emit trap so
    # they become loud failures if reached, not silent undefined symbols.
    if fn == :throw_methoderror || fn == :throw_inexacterror || fn == :throw_undef_if_null || fn == :isdefined
        trap_ptr = Libdl.dlsym(bc.lib_handle, :block_add_trap)
        ccall(trap_ptr, Cvoid, (Ptr{Cvoid},), bc.fctx_handle)
        return nothing
    end
    # No-op / pass-through intrinsics: these don't lower to any Cranelift code
    # in a single-threaded, non-relocating runtime. Return the value argument.
    if fn == :compilerbarrier || fn == :typeassert || fn == :_str_sizehint ||
       fn == :memoryrefget_indices || fn == :not_splat
        length(args) >= 1 && return resolve_operand(bc, args[1], ir)
        return emit_constant(bc, Int64(0))
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
    elseif val isa Core.GlobalRef
        # Module-level constant: resolve to actual type, not GlobalRef
        resolved = getglobal(val.mod, val.name)
        return typeof(resolved)
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

    # Constant index: load just the requested field. Heterogeneous types are fine
    # because we only touch one field, so no select() type-matching is needed.
    k = idx isa Core.QuoteNode ? idx.value : idx
    if k isa Integer
        (1 ≤ k ≤ n) || throw(CompileError("tuple index $k out of range (1:$n)"))
        ptr_id = resolve_operand(bc, obj, ir)
        off = Int32(fieldoffset(T, k))
        ct = cranelift_type(elem_types[k])
        load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
        return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                     bc.fctx_handle, ptr_id, off, ct)
    end

    # Dynamic index: select() needs matching Cranelift types for all arms.
    # Heterogeneous element types cannot be selected (no control-flow-free way
    # to choose between e.g. I64 and a PTR without constructing a tagged union).
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

    # Incomplete (Vararg-tail) or abstract-element Tuple types have no definite
    # layout — fieldoffset/fieldtype throw BoundsError on them (e.g. varargs
    # callees like print_to_string(xs...) whose argtype is
    # Tuple{String, Vararg{Any}}). The concrete-tuple arm above already handled
    # the fully-specialized case; anything Tuple-typed reaching here is
    # unsupported. Throw CompileError (tolerated by the catch → sentinel) so the
    # whole function still emits instead of aborting emission with a raw
    # BoundsError that cascades into misleading verifier errors.
    if T isa DataType && T <: Tuple && !isconcretetype(T)
        throw(CompileError("getfield on non-concrete tuple type $T (Vararg/abstract layout) not yet supported"))
    end

    # getfield on Nothing (dead code after union-splitting): return dummy
    if T === Nothing
        return UInt32(0)
    end

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
            # Load union field as raw pointer if ALL non-Nothing arms are
            # heap-allocated pointer types. nothing → null (0), else → heap ptr.
            arms = _union_arms(field_T)
            non_nothing = filter(!=(Nothing), arms)
            if !isempty(non_nothing) && all(a -> a isa DataType && is_ptr_type(a), non_nothing)
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
        # Store a USABLE pointer in ssa_values (not the parent obj_id) so memrefs
        # that cross boundaries (callee return, PhiNode, untracked arg) keep
        # working via the memoryrefget/set/new fallbacks. For a MemoryRef field
        # (immutable, inline) the leading ptr_or_offset @ +0 IS the element
        # address — load and return it. (GenericMemory is mutable and loadable,
        # so it never reaches Case 2 — it goes through Case 4 and its ssa_values
        # entry is the Memory object pointer; emit_memoryrefnew's fallback loads
        # Memory.ptr from obj+8.) For any other non-loadable field type, fall
        # back to obj_id (no usable leading pointer is known).
        if field_T isa DataType && field_T.name.name === :GenericMemoryRef
            load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
            return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                         bc.fctx_handle, obj_id, Int32(offset), TYPE_I64)
        end
        return obj_id
    end

    # Case 3: bitstype struct field — extract from value (not memory load).
    # ONLY for sizeof<=8 bitstypes: cranelift_type maps these to a real scalar
    # register (I64/I32/I8), so the value lives in a register and we extract the
    # field by shift+mask. Larger bitstypes (NamedTuple sizeof=16, RawToken
    # sizeof=32, ...) are mapped to TYPE_PTR by cranelift_type — they are passed
    # as heap pointers and must use the Case 4 memory-load path below.
    if T isa DataType && isbitstype(T) && sizeof(T) <= 8
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

        # Create mask to extract only the field bits. Use reinterpret (NOT
        # checked Int64(mask)/Int32(mask)) — for a full-width field (field_size
        # == 64), `(UInt64(1)<<64)-1` wraps to 0xffffffffffffffff, whose high
        # bit set makes Int64(...) throw InexactError. emit_constant reinterprets
        # the bits back to Int64 internally, so passing the UInt pattern is safe.
        mask = (UInt64(1) << field_size) - UInt64(1)  # mask for field bits

        # Use consistent type for mask based on struct size
        if struct_size <= 32
            mask_id = emit_constant(bc, reinterpret(Int32, mask & 0xFFFFFFFF % UInt32))
        else
            mask_id = emit_constant(bc, reinterpret(Int64, mask))
        end

        # Apply mask
        and_ptr = Libdl.dlsym(bc.lib_handle, :block_add_band)
        masked_id = ccall(and_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                         bc.fctx_handle, shifted_id, mask_id)

        # Sign extend if field type is signed and smaller than struct size
        if field_T <: Signed && field_size < struct_size
            target_type = cranelift_type(field_T)
            sext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_sextend)
            # Skip if source already matches target (avoid verifier error)
            get_ct = Libdl.dlsym(bc.lib_handle, :block_get_ssa_type)
            from_ct = ccall(get_ct, UInt32, (Ptr{Cvoid}, UInt32), bc.fctx_handle, masked_id)
            if from_ct == target_type
                return masked_id
            end
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
    elem_size = _elem_size(elem_T)

    # Compute element address: ptr + (idx - 1) * elem_size
    # idx - 1
    one_id = emit_constant(bc, Int64(1))  # idx is always i64 (pointer/index domain)
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

    # Load element at elem_addr + 0.
    # Sub-word types (I8/I16): use actual memory width, then uextend to I32 register.
    elem_type_enum = cranelift_type(elem_T)
    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    if elem_size < 4
        mem_type = elem_size == 1 ? TYPE_I8 : TYPE_I16
        raw_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                       bc.fctx_handle, elem_addr_id, Int32(0), mem_type)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, raw_id, TYPE_I32)
    else
        return ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                     bc.fctx_handle, elem_addr_id, Int32(0), elem_type_enum)
    end
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
    elem_size = _elem_size(elem_T)

    # Compute element address: ptr + (idx - 1) * elem_size
    one_id = emit_constant(bc, Int64(1))  # idx is always i64
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
    # memoryrefnew(mem::Union{Memory{T},MemoryRef{T}}, idx::Int, ordered::Bool) → MemoryRef{T}
    # Creates a new MemoryRef pointing to element at 1-based index idx.
    # Two base shapes (see Memory/MemoryRef layouts):
    #   MemoryRef{T}: ptr_or_offset @ off 0 → IS the element address (base-relative)
    #   Memory{T}:    COMPILED-alloc layout (gc.rs __jl_gc_alloc_array_julia):
    #                 length @ off 0, inline element data @ off 8 (like String);
    #                 element-data addr = base+8 (iadd). Real host Memory has a
    #                 Ptr :ptr field @ off 8 (gc.rs 207-209) -- not this path.
    memref_val = args[1]
    idx_val = args[2]

    # Get the base info from ref_tracking (in-function Case 2 / memoryrefnew chain)
    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing

    # Derive the operand's Memory/MemoryRef type for the untracked fallback.
    memref_T = tracked !== nothing ? tracked[3] :
               (let t = get_operand_type(memref_val, ir)
                    t isa Core.Const ? t.val : t
                end)
    is_memory = memref_T isa DataType && memref_T.name.name === :GenericMemory
    elem_T = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_size = _elem_size(elem_T)

    load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
    if tracked !== nothing
        base_id, base_off, _ = tracked
        # MemoryRef: element addr lives at base+off+0 (ptr_or_offset).
        # Memory:    data ptr lives at base+off+8 (Memory.ptr field).
        data_field_off = is_memory ? 8 : 0
        data_ptr_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                            bc.fctx_handle, base_id, Int32(base_off + data_field_off), TYPE_I64)
    else
        # Untracked base (cross-boundary: callee return, PhiNode, or Case-4
        # mutable-field load). The ssa_values entry holds:
        #   MemoryRef{T} (immutable, never Case-4): the element address directly
        #     (set by Case 2's leading-pointer load — ptr_or_offset @ +0).
        #   Memory{T}    (mutable, Case-4 loadable): the Memory OBJECT pointer.
        #     IMPORTANT: this branch is only correct for Memory objects ALLOCATED
        #     BY THIS CODEGEN (emit_memorynew -> __jl_gc_alloc_array_julia,
        #     gc.rs 212-215), whose layout is [type_tag(8)][length@0][inline
        #     element data@8] -- element data is INLINE at obj+8 (like String).
        #     The old `load obj+8` read those inline bytes as a fake pointer ->
        #     SIGBUS on the next deref (the Lexer crash). The element-data
        #     address is obj+8, COMPUTED BY ADDITION (iadd), not loaded. This
        #     untracked is_memory branch is reached for compiled-allocated Memory
        #     (e.g. getfield(io::IOBuffer,:data) where the IOBuffer was built by
        #     compiled code in JuliaSyntax.parse!). Host-passed Vectors use the
        #     MemoryRef path (is_memory=false).
        base_id = resolve_operand(bc, memref_val, ir)
        if is_memory
            eight_id = emit_constant(bc, Int64(8))
            iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
            data_ptr_id = ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                                bc.fctx_handle, base_id, eight_id)
        else
            data_ptr_id = base_id
        end
    end

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

    elem_T, elem_type_enum, base_id, base_off = if tracked !== nothing
        b_id, b_off, memref_T = tracked
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64  # param 1=ordering, param 2=T
        (eT, cranelift_type(eT), b_id, b_off)
    else
        # Untracked (cross-boundary). resolve_operand gives the element address
        # directly (ssa_values for a MemoryRef holds its element address, set by
        # Case 2's leading-pointer load or by emit_memoryrefnew). Derive the
        # element type from the operand's IR type so we load the right width.
        memref_T = get_operand_type(memref_val, ir)
        memref_T = memref_T isa Core.Const ? memref_T.val : memref_T
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
        (eT, cranelift_type(eT), resolve_operand(bc, memref_val, ir), 0)
    end

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

    base_id, base_off, elem_type_enum = if tracked !== nothing
        b_id, b_off, memref_T = tracked
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
        (b_id, b_off, cranelift_type(eT))
    else
        # Untracked (cross-boundary). resolve_operand gives the element address.
        memref_T = get_operand_type(memref_val, ir)
        memref_T = memref_T isa Core.Const ? memref_T.val : memref_T
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
        (resolve_operand(bc, memref_val, ir), 0, cranelift_type(eT))
    end

    val_id = resolve_operand(bc, val, ir)

    store_ptr = Libdl.dlsym(bc.lib_handle, :block_add_store)
    ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
          bc.fctx_handle, base_id, Int32(base_off), val_id, elem_type_enum)

    # memoryrefset! returns the stored value
    return val_id
end

function emit_isa(bc::BuilderCtx, args, ir)
    # isa(x, Type) — handles:
    #   1. isa(x, Nothing): tagged-sentinel check on pointer values
    #   2. isa(x, T) where x::Union{Nothing, T}: check value != nothing_tag
    #   3. isa(x, DataType): load type tag from object header, compare to target's type pointer
    # args[1] = value, args[2] = the type to check against
    target_type = args[2]
    target_type isa QuoteNode && (target_type = target_type.value)
    target_type isa Core.Const && (target_type = target_type.val)

    # Targeted lowering for the generic kwcall sorter: when x is a Vararg-tuple
    # produced by Core._apply_iterate over a runtime Vector (recorded in
    # vararg_tuple_coll), `isa(x, Tuple{})` is the "any kwargs set?" check and
    # lowers to `length(vec) == 0`. A Vector's length lives at offset +16
    # (:size field, Tuple{Int64}).
    if target_type === Tuple{} && args[1] isa Core.SSAValue &&
       haskey(bc.vararg_tuple_coll, args[1])
        vec_id = bc.vararg_tuple_coll[args[1]]
        load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
        len_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                       bc.fctx_handle, vec_id, Int32(16), TYPE_I64)
        zero_id = emit_constant(bc, Int64(0))
        icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                       bc.fctx_handle, ICMP_EQ, len_id, zero_id)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                     bc.fctx_handle, result, TYPE_I32)
    end

    val_id = resolve_operand(bc, args[1], ir)

    if target_type === Nothing
        # nothing in union fields is tagged, not raw null (0x0).
        nothing_tag = get_nothing_tag()
        zero_id = emit_constant(bc, Int64(nothing_tag))
        fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                      bc.fctx_handle, ICMP_EQ, val_id, zero_id)
        # uextend I8 → I32 for Bool ABI
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, result, TYPE_I32)
    end

    # Case 2: isa(x, T) where the SSA value's IR type is Union{Nothing, T}.
    # In this case, the only non-nothing arm IS T, so value != nothing_tag suffices.
    val_arg = args[1]
    if val_arg isa Core.SSAValue
        ssatype = ir.stmts[val_arg.id][:type]
        if ssatype isa Core.Union
            utypes = Base.uniontypes(ssatype)
            if length(utypes) == 2 && Nothing in utypes && target_type in utypes
                # x is Union{Nothing, T}; isa(x, T) ⟺ x != nothing_tag
                nothing_tag = get_nothing_tag()
                tag_id = emit_constant(bc, Int64(nothing_tag))
                fn_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
                result = ccall(fn_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                              bc.fctx_handle, ICMP_NE, val_id, tag_id)
                ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
                return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                            bc.fctx_handle, result, TYPE_I32)
            end
        end
    end

    # Case 3: isa(x, T) for union types without Nothing where T is a heap-allocated arm.
    # Since all arms are heap types, there are no sentinels — all values are valid
    # pointers. We can safely load the type tag from the object header at offset 0
    # and compare it to pointer_from_objref(T).
    if val_arg isa Core.SSAValue
        ssatype = ir.stmts[val_arg.id][:type]
        if ssatype isa Core.Union
            utypes = Base.uniontypes(ssatype)
            # Only for unions WITHOUT Nothing (Case 2 already handles that)
            if !(Nothing in utypes) && target_type in utypes && target_type isa DataType
                T = target_type
                type_ptr = pointer_from_objref(T)
                type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))
                # Load jl_datatype_t* tag from object header at offset 0
                load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
                loaded_tag = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                                 bc.fctx_handle, val_id, Int32(0), TYPE_I64)
                # Compare loaded tag to the target type's pointer
                icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
                result = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                             bc.fctx_handle, ICMP_EQ, loaded_tag, type_ptr_id)
                ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
                return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                            bc.fctx_handle, result, TYPE_I32)
            end
        end
    end

    # Case 4: isa(x, T) for a concrete DataType target where x is a heap pointer
    # (covers isa(x, Tuple{}) — e.g. checking whether a varargs tuple is empty —
    # and isa(x, SomeConcreteStruct)). Load x's type tag from the object header
    # (offset 0) and compare to pointer_from_objref(T). Tuples are ALWAYS heap
    # objects (even Tuple{}, which isbitstype reports as true / sizeof 0), so
    # include T <: Tuple; exclude scalar bitstypes (Int etc.) which aren't heap ptrs.
    if target_type isa DataType && isconcretetype(target_type) &&
       (target_type <: Tuple || !isbitstype(target_type))
        type_ptr = pointer_from_objref(target_type)
        type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))
        load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
        loaded_tag = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                         bc.fctx_handle, val_id, Int32(0), TYPE_I64)
        icmp_ptr = Libdl.dlsym(bc.lib_handle, :block_add_icmp)
        result = ccall(icmp_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                     bc.fctx_handle, ICMP_EQ, loaded_tag, type_ptr_id)
        ext_ptr = Libdl.dlsym(bc.lib_handle, :block_add_uextend)
        return ccall(ext_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, result, TYPE_I32)
    end

    throw(CompileError("unsupported isa target: $target_type"))
end

function emit_select(bc::BuilderCtx, args, ir)
    # ifelse(cond, a, b) → Cranelift select(cond, a, b)
    cond_id = resolve_operand(bc, args[1], ir)
    true_id = resolve_operand(bc, args[2], ir)
    false_id = resolve_operand(bc, args[3], ir)
    sel_ptr = Libdl.dlsym(bc.lib_handle, :block_add_select)
    return ccall(sel_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32, UInt32),
                bc.fctx_handle, cond_id, true_id, false_id)
end

# Handle :foreigncall expressions — C function calls from Julia's IR lowering.
# Simple builtins are inlined; complex ones emit runtime imports.
function emit_foreigncall(bc::BuilderCtx, e::Expr, ir, stmt_idx)
    call_name = e.args[1]  # (:jl_value_ptr,) as QuoteNode, Expr(:tuple), or bare Symbol
    fn_name = call_name isa QuoteNode ? call_name.value :
              (call_name isa Expr && call_name.head == :tuple) ? call_name.args[1] :
              call_name isa Tuple ? call_name[1] : call_name
    # Unwrap QuoteNode again (may be nested: Expr(:tuple, QuoteNode(:sym)))
    fn_name = fn_name isa QuoteNode ? fn_name.value : fn_name
    rettype = e.args[2]    # Return type
    arg_types = e.args[3]   # svec of argument types
    nargs = length(arg_types)
    cc_args = length(e.args) >= 6 ? e.args[6:end] : []  # actual argument values after name, ret, types, nreq, cc

    # Inline simple builtins that don't need C calls
    if fn_name == :jl_value_ptr
        # pointer_from_objref(x) — x is already a heap pointer in our world
        return resolve_operand(bc, cc_args[1], ir)
    elseif fn_name == :jl_string_ptr
        # String data pointer = string_obj_ptr + 8 (skip the i64 length header)
        str_id = resolve_operand(bc, cc_args[1], ir)
        off_id = emit_constant(bc, Int64(8))
        iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
        return ccall(iadd_ptr, UInt32, (Ptr{Cvoid}, UInt32, UInt32),
                    bc.fctx_handle, str_id, off_id)
    elseif fn_name == :jl_set_errno
        # Ignore errno (we don't track it)
        return nothing
    elseif fn_name == :jl_errno
        # Return 0 (no errno tracking)
        return emit_constant(bc, Int32(0))
    elseif fn_name == :jl_strtod_c
        # strtod(ptr, endptr) — C standard library function
        # Declare as import once per builder context
        import_name = "strtod"
        if !(import_name in bc.imported_foreign)
            push!(bc.imported_foreign, import_name)
            declare_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_import)
            param_types = [TYPE_I64, TYPE_I64]  # const char*, char**
            ccall(declare_ptr, Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                  bc.builder_handle, import_name, TYPE_F64, param_types,
                  length(param_types))
        end
        nreq = length(cc_args)
        @assert nreq >= 2 "strtod_c needs at least 2 args, got $nreq"
        str_ptr_id = resolve_operand(bc, cc_args[1], ir)
        endptr_ref_id = resolve_operand(bc, cc_args[2], ir)
        return emit_call_runtime(bc, import_name, UInt32[str_ptr_id, endptr_ref_id])
    elseif fn_name == :jl_strtof_c
        # strtof(ptr, endptr) — C standard library function (Float32 variant).
        # Mirrors jl_strtod_c above but returns TYPE_F32. Resolves against the
        # host libm at .so load time (linker uses no -lm, like strtod).
        import_name = "strtof"
        if !(import_name in bc.imported_foreign)
            push!(bc.imported_foreign, import_name)
            declare_ptr = Libdl.dlsym(bc.lib_handle, :builder_declare_import)
            param_types = [TYPE_I64, TYPE_I64]  # const char*, char**
            ccall(declare_ptr, Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                  bc.builder_handle, import_name, TYPE_F32, param_types,
                  length(param_types))
        end
        nreq = length(cc_args)
        @assert nreq >= 2 "strtof_c needs at least 2 args, got $nreq"
        str_ptr_id = resolve_operand(bc, cc_args[1], ir)
        endptr_ref_id = resolve_operand(bc, cc_args[2], ir)
        return emit_call_runtime(bc, import_name, UInt32[str_ptr_id, endptr_ref_id])
    else
        error("Unsupported foreigncall: $fn_name")
    end
end

function emit_memoryrefunset(bc::BuilderCtx, args, ir)
    # memoryrefunset!(memref::MemoryRef{T}, ordering, boundscheck) → Nothing
    # Stores zero at the MemoryRef address (GC safety for reference types).
    memref_val = args[1]

    tracked = (memref_val isa Core.SSAValue && haskey(bc.ref_tracking, memref_val)) ?
              bc.ref_tracking[memref_val] : nothing

    base_id, base_off, elem_type_enum = if tracked !== nothing
        b_id, b_off, memref_T = tracked
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
        (b_id, b_off, cranelift_type(eT))
    else
        # Untracked (cross-boundary). resolve_operand gives the element address.
        memref_T = get_operand_type(memref_val, ir)
        memref_T = memref_T isa Core.Const ? memref_T.val : memref_T
        eT = memref_T isa DataType && length(memref_T.parameters) >= 2 ?
             memref_T.parameters[2] : Int64
        (resolve_operand(bc, memref_val, ir), 0, cranelift_type(eT))
    end

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

    # __jl_array_new_1d(atype: ptr, mem_ptr: ptr, nel: i64) -> ptr  (pure-Rust)
    array_new_args = UInt32[TYPE_PTR, TYPE_PTR, TYPE_I64]
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

# emit_call_import: resolve arguments from IR and emit a call to a declared import
# (either a runtime import or a self-import for recursion).
function emit_call_import(bc::BuilderCtx, func_name::String, args, ir)
    arg_ids = UInt32[resolve_operand(bc, a, ir) for a in args]
    return emit_call_runtime(bc, func_name, arg_ids)
end

function emit_memorynew(bc::BuilderCtx, args, ir)
    # Core.memorynew(Memory{T}, n) → allocate raw memory with Julia-compatible layout
    mem_T = args[1]  # Memory{Int64} DataType
    n = args[2]      # length

    elem_T = mem_T isa DataType && length(mem_T.parameters) >= 2 ?
             mem_T.parameters[2] : Int64  # param 1=ordering, param 2=T
    elem_size = UInt32(_elem_size(elem_T))

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
        if isghost(ET)
            push!(offsets, current_offset)  # ghost element: no space, but still addressable
            continue
        end
        # Align to natural boundary of the type
        # Use pointer width for heap-reference types (typeof does not have sizeof)
        elem_sz = try sizeof(ET) catch; 8 end
        align = elem_sz
        current_offset = cld(current_offset, align) * align
        push!(offsets, current_offset)
        current_offset += elem_sz
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
        elem_T = elem_types[i]
        isghost(elem_T) && continue  # ghost elements (e.g. Nothing) take no space
        elem_id = resolve_operand(bc, arg, ir)
        field_type_enum = cranelift_type(elem_T)
        ccall(store_ptr, Cvoid, (Ptr{Cvoid}, UInt32, Int32, UInt32, UInt32),
              bc.fctx_handle, ptr_id, Int32(offsets[i]), elem_id, field_type_enum)
    end

    return ptr_id
end

# Sentinel for "_const_value could not resolve this to a compile-time constant".
struct _NotConst end

# Resolve an IR operand to its compile-time Julia value, or _NotConst() if it is
# not a known constant. Used by emit_apply_iterate to constant-fold kwarg/varargs
# splats whose collection is a literal.
function _const_value(val, ir)
    val isa Core.Const && return val.val
    val isa QuoteNode && return val.value
    val isa Core.GlobalRef && return _const_value(getglobal(val.mod, val.name), ir)
    val === nothing && return nothing
    val isa Number && return val
    val isa AbstractString && return val
    val isa Function && return val
    val isa Symbol && return val
    val isa Bool && return val
    val isa Tuple && begin
        els = [_const_value(x, ir) for x in val]
        any(e -> e isa _NotConst, els) && return _NotConst()
        return tuple(els...)
    end
    val isa NamedTuple && begin
        vals = [_const_value(x, ir) for x in values(val)]
        any(v -> v isa _NotConst, vals) && return _NotConst()
        return NamedTuple{keys(val)}(vals)
    end
    val isa Core.SSAValue || return _NotConst()
    t = ir.stmts[val.id][:type]
    t isa Core.Const && return t.val
    stmt = ir.stmts[val.id][:stmt]
    if stmt isa Expr && stmt.head == :call && length(stmt.args) >= 1 &&
       (stmt.args[1] === Core.tuple || (stmt.args[1] isa Core.GlobalRef && stmt.args[1].name === :tuple))
        els = [_const_value(a, ir) for a in stmt.args[2:end]]
        any(e -> e isa _NotConst, els) && return _NotConst()
        return tuple(els...)
    end
    return _NotConst()
end

# Core._apply_iterate(iterate, g, coll) = g(iterate(coll)...) — the kwarg/varargs
# splat lowering. Compile-time-evaluate when `coll` is a known constant (e.g.
# constant kwargs to open_flags(; read=true, …)); emit the result as a heap
# pointer. Dynamic collections throw CompileError (tolerated → sentinel).
function emit_apply_iterate(bc::BuilderCtx, args, ir, stmt_idx)
    length(args) < 3 && throw(CompileError("_apply_iterate needs >=3 args"))
    coll = _const_value(args[3], ir)
    if !(coll isa _NotConst)
        result = Core._apply_iterate(Base.iterate, Core.tuple, coll)
        return emit_constant(bc, result)
    end
    # Non-constant collection (e.g. the generic kwcall sorter building a Vector of
    # set-kwarg names at runtime). When the result type is a NON-CONCRETE (Vararg)
    # Tuple, the value is only ever consumed by `isa(result, Tuple{})` (the
    # any-kwargs-set check). Record the collection's value id so emit_isa can lower
    # that to `length(coll) == 0`, and return the collection id as the SSA value.
    resT = try; ir.stmts[stmt_idx][:type]; catch _; nothing; end
    if resT isa DataType && resT <: Tuple && !isconcretetype(resT)
        coll_id = resolve_operand(bc, args[3], ir)
        bc.vararg_tuple_coll[Core.SSAValue(stmt_idx)] = coll_id
        return coll_id
    end
    throw(CompileError("_apply_iterate: non-constant collection not yet supported"))
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
        if size_arg isa Tuple && length(size_arg) == 1
            nel = size_arg[1]
            nel_id = emit_constant(bc, Int64(nel))
        elseif size_arg isa Core.SSAValue
            # Dynamic size. The size arg is `Core.tuple(n)` of type Tuple{Int64}.
            # emit_core_tuple PASSES single-element tuples through (no heap allocation),
            # so for Tuple{Int64} the SSA already IS the element-count Int64 — loading
            # it as a pointer (old code) dereferences the integer length (e.g. 0x5),
            # SIGSEGV. Only multi-element tuples are heap-allocated and need a load.
            local size_T = get_operand_type(size_arg, ir)
            size_T = size_T isa Core.Const ? size_T.val : size_T
            if size_T isa DataType && size_T <: Tuple && length(size_T.parameters) == 1
                # 1-element tuple passed through by emit_core_tuple: value IS nel.
                nel_id = resolve_operand(bc, size_arg, ir)
            else
                tuple_ptr_id = resolve_operand(bc, size_arg, ir)
                load_ptr = Libdl.dlsym(bc.lib_handle, :block_add_load)
                nel_id = ccall(load_ptr, UInt32, (Ptr{Cvoid}, UInt32, Int32, UInt32),
                             bc.fctx_handle, tuple_ptr_id, Int32(0), TYPE_I64)
            end
        else
            error("emit_new(array): only 1-d arrays supported, got size $size_arg")
        end
        # The first field arg is the MemoryRef SSA value returned by emit_memoryref_from_mem.
        # Its .mem field is the Memory pointer (from __jl_gc_alloc_array_julia via emit_memorynew).
        # Extract it from ref_tracking and pass to __jl_array_new_1d instead of allocating a
        # separate raw element buffer.
        memref_arg = field_args[1]
        if memref_arg isa Core.SSAValue && haskey(bc.ref_tracking, memref_arg)
            mem_ptr_id, _, _ = bc.ref_tracking[memref_arg]
        else
            error("emit_new(array): memref not in ref_tracking")
        end
        type_ptr = pointer_from_objref(T)
        type_ptr_id = emit_constant(bc, Int64(reinterpret(UInt64, type_ptr)))
        return emit_call_runtime(bc, "__jl_array_new_1d", UInt32[type_ptr_id, mem_ptr_id, nel_id])
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
