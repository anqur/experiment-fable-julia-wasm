# eDSL builder emitter for Julia IRCode → Rust builder API calls
# Replaces CLIF text generation with direct Rust FFI calls

using WasmCodegen: ScalarRepr, scalar_repr, isghost, wasm_valtype

# Type enums matching Rust side (must match builder.rs)
const TYPE_I32 = 0
const TYPE_I64 = 1
const TYPE_F32 = 2
const TYPE_F64 = 3
const TYPE_PTR = 4

# Julia type to Cranelift type enum mapping (kept from original)
const CRANELIFT_TYPE_MAP = IdDict{Any,UInt32}(
    Int64=>TYPE_I64, UInt64=>TYPE_I64, Int32=>TYPE_I32, UInt32=>TYPE_I32,
    Int16=>TYPE_I32, UInt16=>TYPE_I32, Int8=>TYPE_I32, UInt8=>TYPE_I32,
    Bool=>TYPE_I32, Char=>TYPE_I32, Float64=>TYPE_F64, Float32=>TYPE_F32,
)

# Get Cranelift type enum for Julia type
function cranelift_type(T)
    t = get(CRANELIFT_TYPE_MAP, T, nothing)
    t !== nothing && return t
    T isa DataType && Base.ismutabletype(T) && !(T <: Ptr) && return TYPE_PTR
    r = scalar_repr(T); r === nothing && throw(CompileError("unsupported type $T"))
    return r.vt == WasmTools.I64 ? TYPE_I64 : r.vt == WasmTools.I32 ? TYPE_I32 :
           r.vt == WasmTools.F64 ? TYPE_F64 : TYPE_F32
end

# Type mapping for return type compatibility (kept from original)
function is_ptr_type(T)
    T isa DataType && (Base.ismutabletype(T) || T === String) && !(T <: Ptr)
end

# Context for building functions via Rust API
mutable struct BuilderCtx
    builder_handle::Ptr{Cvoid}  # Pointer to Rust BuilderContext
    lib_handle::Ptr{Cvoid}       # Pointer to loaded native-builder library
    func_handle::Ptr{Cvoid}       # Pointer to current FunctionBuilder
    current_block::Ptr{Cvoid}    # Pointer to current BlockBuilder
    next_value_id::UInt32         # Counter for SSA values
    # SSA value tracking
    ssa_values::Dict{Core.SSAValue, UInt32}  # SSA → value ID mapping
    arg_values::Dict{Core.Argument, UInt32}  # Arguments → value ID mapping
    const_values::Dict{Any, UInt32}           # Constants → value ID mapping
    ir::Any  # Store reference to IRCode for constant resolution
end

function BuilderCtx(lib_path::String)
    lib = Libdl.dlopen(lib_path)
    create_ptr = Libdl.dlsym(lib, :create_builder)
    ctx = ccall(create_ptr, Ptr{Cvoid}, ())
    BuilderCtx(ctx, lib, C_NULL, C_NULL, 0,
                Dict{Core.SSAValue, UInt32}(),
                Dict{Core.Argument, UInt32}(),
                Dict{Any, UInt32}(), nothing)
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

# Main entry point: compile Julia function to object file via eDSL
function emit_function_via_builder(interp::WasmInterp, f, argtypes::Type{<:Tuple}; name::String="entry", output_path::String=tempname()*".o")
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    matches === nothing && error("no method found for $f")
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    length(result) == 1 || throw(CompileError("expected unique match"))
    ir, rettype = result[1]

    # Get native-builder library path
    builder_lib = get_native_builder_lib()

    # Create builder context
    bc = BuilderCtx(builder_lib)
    bc.ir = ir  # Store IR reference for constant resolution

    try
        # Initialize argument mappings for all possible arguments Julia might use
        # Julia can reference arguments beyond the function parameters (like Argument(0), Argument(1), etc.)
        for i in 1:10  # Support up to 10 arguments for now
            arg = Core.Argument(i)
            bc.arg_values[arg] = UInt32(i - 1)  # Rust uses 0-based indexing
        end

        # Add function
        ret_type_enum = cranelift_type(rettype)
        param_type_enums = UInt32[cranelift_type(t) for t in mi.specTypes.parameters[2:end]]  # Skip tuple type

        add_func_ptr = Libdl.dlsym(bc.lib_handle, :builder_add_function)
        bc.func_handle = ccall(add_func_ptr, Ptr{Cvoid},
                               (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Csize_t),
                               bc.builder_handle, name, ret_type_enum, param_type_enums, length(param_type_enums))

        bc.func_handle == C_NULL && error("Failed to add function")

        # Process IRCode blocks
        cfg = ir.cfg
        for (bi, block) in enumerate(cfg.blocks)
            emit_block(bc, block, bi, ir)
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

# Emit a single block
function emit_block(bc::BuilderCtx, block, block_index::Int, ir)
    # Add block
    block_name = "block$(block_index-1)"
    add_block_ptr = Libdl.dlsym(bc.lib_handle, :function_add_block)
    bc.current_block = ccall(add_block_ptr, Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{UInt8}),
                            bc.func_handle, block_name)

    bc.current_block == C_NULL && error("Failed to add block")

    # Process instructions
    for (idx, si) in enumerate(block.stmts)
        e = ir.stmts[si][:stmt]
        emit_instruction(bc, e, ir, si)
    end
end

# Emit individual instructions
function emit_instruction(bc::BuilderCtx, e, ir, stmt_idx::Int)
    if e isa Expr && e.head == :call
        # Handle function calls (intrinsics, etc.)
        f = e.args[1]
        args = e.args[2:end]

        if f isa Core.GlobalRef && f.name == :add_int
            # Example: integer addition
            if length(args) >= 2
                lhs = resolve_operand(bc, args[1], ir)
                rhs = resolve_operand(bc, args[2], ir)

                result_ptr = Ref{UInt32}()
                add_iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
                ccall(add_iadd_ptr, Cvoid,
                      (Ptr{Cvoid}, Ptr{UInt32}, UInt32, UInt32),
                      bc.current_block, result_ptr, lhs, rhs)

                # Track the resulting SSA value
                result_id = result_ptr[]
                ssa_val = Core.SSAValue(stmt_idx)
                bc.ssa_values[ssa_val] = result_id
            end
        elseif f isa Core.IntrinsicFunction
            # Handle intrinsics (add_float, sub_int, etc.)
            emit_intrinsic(bc, f, args, ir, stmt_idx)
        end
    elseif e isa Core.ReturnNode
        # Handle return statement
        val = try e.val; catch; nothing end
        if val !== nothing
            value_id = resolve_operand(bc, val, ir)
            add_return_ptr = Libdl.dlsym(bc.lib_handle, :block_add_return)
            ccall(add_return_ptr, Cvoid, (Ptr{Cvoid}, UInt32), bc.current_block, value_id)
        end
    elseif e isa Core.GotoNode
        # Handle unconditional jumps
        # TODO: Implement jump emission
    elseif e isa Core.GotoIfNot
        # Handle conditional branches
        # TODO: Implement conditional jump emission
    end
end

# Emit intrinsic operations
function emit_intrinsic(bc::BuilderCtx, f, args, ir, stmt_idx)
    if f === Core Intrinsics.add_int
        # Integer addition
        if length(args) >= 2
            lhs = resolve_operand(bc, args[1], ir)
            rhs = resolve_operand(bc, args[2], ir)

            result_ptr = Ref{UInt32}()
            add_iadd_ptr = Libdl.dlsym(bc.lib_handle, :block_add_iadd)
            ccall(add_iadd_ptr, Cvoid,
                  (Ptr{Cvoid}, Ptr{UInt32}, UInt32, UInt32),
                  bc.current_block, result_ptr, lhs, rhs)

            # Track the resulting SSA value
            result_id = result_ptr[]
            ssa_val = Core.SSAValue(stmt_idx + 1)
            bc.ssa_values[ssa_val] = result_id
        end
    elseif f === Core Intrinsics.sub_int
        # Integer subtraction - needs implementation
        # TODO: Add sub_int handling when implemented in Rust side
    elseif f === Core Intrinsics.mul_int
        # Integer multiplication - needs implementation
        # TODO: Add mul_int handling when implemented in Rust side
    elseif f === Core Intrinsics.eq_int
        # Integer equality comparison
        # TODO: Implement comparison operations
    else
        # Unsupported intrinsic
        error("Unsupported intrinsic: $f")
    end
end

# Resolve operand to SSA value ID
function resolve_operand(bc::BuilderCtx, val, ir)
    if val isa Core.SSAValue
        # Look up SSA value in our tracking dictionary
        if haskey(bc.ssa_values, val)
            return bc.ssa_values[val]
        else
            error("SSA value $val not found in tracking")
        end
    elseif val isa Core.Argument
        # Look up argument value in our tracking dictionary
        if haskey(bc.arg_values, val)
            return bc.arg_values[val]
        else
            error("Argument $val not found in tracking")
        end
    elseif isa(val, Number)
        # For constants, check if we've already created one
        if haskey(bc.const_values, val)
            return bc.const_values[val]
        else
            # TODO: Add constant creation via FFI
            # For now, use a simple hash-based ID
            const_id = bc.next_value_id
            bc.next_value_id += 1
            bc.const_values[val] = const_id
            return const_id
        end
    else
        error("Unsupported operand type: $(typeof(val))")
    end
end

# Find native-builder library
function get_native_builder_lib()
    # Look in the native-builder target directory
    base_dir = joinpath(dirname(@__DIR__), "..", "native-builder", "target")

    # Try both release and debug profiles
    for profile in ("release", "debug")
        lib_name = Sys.isapple() ? "libnative_builder.dylib" :
                   Sys.islinux()  ? "libnative_builder.so" :
                   error("unsupported platform")
        path = joinpath(base_dir, profile, lib_name)
        isfile(path) && return path
    end

    error("native-builder library not found. Build with: cd native-builder && cargo build --release")
end