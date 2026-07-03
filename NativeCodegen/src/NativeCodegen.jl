"""
    NativeCodegen

Translator from Julia's optimized SSA IR (`IRCode`) to native machine code via
Cranelift. Reuses WasmCodegen's frontend.
"""
module NativeCodegen

using Libdl
using WasmCodegen: WasmCodegen, WasmInterp, CompileError
const ScalarRepr = WasmCodegen.ScalarRepr
const _SCALAR_REPRS = WasmCodegen._SCALAR_REPRS
const scalar_repr = WasmCodegen.scalar_repr
const isghost = WasmCodegen.isghost
const ghost_instance = WasmCodegen.ghost_instance
const wasm_valtype = WasmCodegen.wasm_valtype
const valkind_sym = WasmCodegen.valkind_sym
const from_wire = WasmCodegen.from_wire
const to_wire = WasmCodegen.to_wire
const INTERCEPTS = WasmCodegen.INTERCEPTS
const EXTERNREF_TYPES = WasmCodegen.EXTERNREF_TYPES
const register_externref_type! = WasmCodegen.register_externref_type!
const register_import_intercept! = WasmCodegen.register_import_intercept!
const CC = Core.Compiler

include("reprs.jl")
include("interp.jl")
include("intrinsics.jl")
include("builder_emit.jl")

# === Bridge: native compilation + FFI ===

struct NativeCompilation
    so_path::String      # Path to generated .so file
    func_name::String    # Exported symbol (prefixed, e.g. "__jl_entry_entry")
end

# Prefix every exported entry symbol so it can NEVER collide with a Cranelift
# libcall name. Cranelift lowers some IR ops (ceil_llvm/floor_llvm, and the
# mem* family) to external libcalls resolved by symbol name at .so load. If an
# entry were exported under a bare name like "ceil", the libcall would bind to
# the entry itself → infinite self-recursion (StackOverflowError) — observed
# when a test named its entry "ceil"/"floor". With this prefix no user/test
# `name` can shadow a libcall. `comp.func_name` carries the prefixed symbol, so
# native_callable_from_so / compile_and_call dlsym it consistently.
const ENTRY_SYMBOL_PREFIX = "__jl_entry_"

const _BUILDER_LIB_PATH = Ref{String}()
const _RUNTIME_LIB_PATH = Ref{String}()

function _init_builder_lib()
    isassigned(_BUILDER_LIB_PATH) && return _BUILDER_LIB_PATH[]
    lib_name = Sys.isapple() ? "libnative_builder.dylib" :
               Sys.islinux()  ? "libnative_builder.so" :
               error("unsupported platform")
    dir = joinpath(dirname(@__DIR__), "..", "native-builder", "target")
    path = _debug_artifact(dir, lib_name)
    path === nothing && error("native-builder library not found. Build with: cd native-builder && cargo build")
    _BUILDER_LIB_PATH[] = path
    return path
end

function _init_runtime_lib()
    isassigned(_RUNTIME_LIB_PATH) && return _RUNTIME_LIB_PATH[]
    lib_name = Sys.isapple() ? "libnative_backend.a" :
               Sys.islinux()  ? "libnative_backend.a" :
               error("unsupported platform")
    dir = joinpath(dirname(@__DIR__), "..", "native-backend", "target")
    path = _debug_artifact(dir, lib_name)
    path === nothing && error("native-backend runtime library not found. Build with: cd native-backend && cargo build")
    _RUNTIME_LIB_PATH[] = path
    return path
end

# Resolve the dev-profile (debug) artifact ONLY. Release artifacts are never
# loaded during local development — they carry no debug-assertions and a stale
# release build has historically shadowed a fresh debug one, masking real
# IR-construction bugs. Perf measurement with `--release` should be done
# out-of-band; this loader refuses to touch `target/release`. Returns nothing
# if no debug artifact exists (callers raise a "build with: cargo build" error).
function _debug_artifact(target_dir, lib_name)
    path = joinpath(target_dir, "debug", lib_name)
    isfile(path) ? path : nothing
end

function compile_native(f, argtypes::Type{<:Tuple}; name::String="entry")
    interp = WasmInterp()

    # Prefix the exported symbol so it cannot collide with a Cranelift libcall
    # (see ENTRY_SYMBOL_PREFIX). `name` is just a human label; the symbol is
    # derived from it and used consistently for both emission and dlsym.
    symbol = ENTRY_SYMBOL_PREFIX * name

    # Generate object file via eDSL builder
    temp_obj = tempname() * ".o"
    emit_function_via_builder(interp, f, argtypes; name=symbol, output_path=temp_obj)

    # Link object file with runtime library to create final .so
    builder_lib = _init_builder_lib()
    runtime_lib = _init_runtime_lib()
    lib = Libdl.dlopen(builder_lib)
    link_ptr = Libdl.dlsym(lib, :link_object_to_so)

    so_path = tempname() * ".so"
    status = ccall(link_ptr, Cint, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}),
                  temp_obj, runtime_lib, so_path)
    status != 0 && error("Linking failed")

    # Clean up temporary object file
    rm(temp_obj)

    return NativeCompilation(so_path, symbol)
end

# Helper: check if return type needs Ptr{Cvoid} (pointer to GC object)
_is_ptr_type(T) = (T isa DataType && !(T <: Ptr) && (
    Base.ismutabletype(T) || T === String || T <: Tuple ||
    (isconcretetype(T) && !isbitstype(T) &&
     !(T.name.name in (:GenericMemoryRef, :GenericMemory)))
))

_is_i64(T) = let r = scalar_repr(T); !_is_ptr_type(T) && r !== nothing && r.bits == 64 && !r.isfloat; end
_is_f64(T) = let r = scalar_repr(T); !_is_ptr_type(T) && r !== nothing && r.isfloat && r.bits == 64; end
_is_f32(T) = let r = scalar_repr(T); !_is_ptr_type(T) && r !== nothing && r.isfloat && r.bits == 32; end

# === N-argument ccall dispatcher ===
# One @generated function handles ANY arity and type combination, replacing the
# old enumerated _call0 / _call1_{i64,i32,f64,f32} / _call2_{ii,ij,ji,jj,ff,fi,pi}
# ladder (which was O(3^N) and capped at 2 args). The ccall argument-type tuple
# and return type are built from the DECLARED arg-type tuple `AT` and return type
# `RT`, so the compiled entry's ABI (what `cranelift_type` produced) matches
# exactly. Marshalling rules (preserved from the old helpers):
#   arg  : ptr→Ptr{Cvoid}(pointer_from_objref)  f64→Float64  f32→Float32(abi)
#          i64→Int64(to_wire)  else→Int32(to_wire)
#   ret  : Nothing→Cvoid  ptr→Ptr{Cvoid}(unsafe_pointer_to_objref)
#          Float64→Float64  Float32→Float32  else→Int64 then from_wire
# `AT` is the declared arg-type tuple (classify on it, NOT on typeof(value), so a
# value passed where a wider type is declared keeps the declared width).
@generated function _gcall(ptr::Ptr{Cvoid}, ::Type{RT}, ::Type{AT}, args...) where {RT, AT<:Tuple}
    ccall_types = Type[]
    arg_exprs = Expr[]
    for i in eachindex(AT.parameters)
        T = AT.parameters[i]
        if T <: Type
            # Type values (e.g. Type{Float64}, Type{Int64}) are singleton DataTypes.
            # Pass as Ptr{Cvoid} via pointer_from_objref.
            push!(ccall_types, Ptr{Cvoid})
            push!(arg_exprs, :(pointer_from_objref(getfield(args,$i))))
        elseif _is_ptr_type(T)
            push!(ccall_types, Ptr{Cvoid})
            # pointer_from_objref works on mutable structs, String, and Tuple.
            # For immutable non-bitstype structs (e.g. GreenNode), wrap with Ref.
            if isconcretetype(T) && !isbitstype(T) && !Base.ismutabletype(T) &&
               T !== String && !(T <: Tuple)
                push!(arg_exprs, :(unsafe_load(Ptr{Ptr{Cvoid}}(pointer_from_objref(Ref(getfield(args,$i)))))))
            else
                push!(arg_exprs, :(pointer_from_objref(getfield(args,$i))))
            end
        elseif _is_f64(T)
            push!(ccall_types, Float64); push!(arg_exprs, :(getfield(args,$i)))
        elseif _is_f32(T)
            push!(ccall_types, Float32); push!(arg_exprs, :(Float32(getfield(args,$i))))
        elseif _is_i64(T)
            push!(ccall_types, Int64); push!(arg_exprs, :(Int64(to_wire($T, getfield(args,$i)))))
        else
            push!(ccall_types, Int32); push!(arg_exprs, :(Int32(to_wire($T, getfield(args,$i)))))
        end
    end
    sig = Expr(:tuple, ccall_types...)
    if RT === Nothing
        return :(ccall(ptr, Cvoid, $sig, $(arg_exprs...)); nothing)
    elseif _is_ptr_type(RT)
        return :(unsafe_pointer_to_objref(ccall(ptr, Ptr{Cvoid}, $sig, $(arg_exprs...))))
    elseif RT isa Union
        # Union return types where all non-Nothing arms are pointer types:
        # return as Ptr{Cvoid} with tagged-nothing check.
        # nothing in union returns is tagged (not C_NULL, not 0x0).
        # Example: children(GreenNode) → Union{Nothing, Vector{GreenNode{...}}}
        arms = _union_arms(RT)
        non_nothing = filter(!=(Nothing), arms)
        if !isempty(non_nothing) && all(_is_ptr_type, non_nothing)
            return :(let p = ccall(ptr, Ptr{Cvoid}, $sig, $(arg_exprs...))
                      p == Ptr{Cvoid}(get_nothing_tag()) ? nothing : unsafe_pointer_to_objref(p)
                  end)
        end
        error("unsupported Union return type: $RT (arms contain non-pointer types)")
    elseif RT === Float64
        return :(ccall(ptr, Float64, $sig, $(arg_exprs...)))
    elseif RT === Float32
        return :(ccall(ptr, Float32, $sig, $(arg_exprs...)))
    else
        return :(from_wire($RT, ccall(ptr, Int64, $sig, $(arg_exprs...))))
    end
end

# Normalize the no-args convention used across the bridge: a single `Tuple{}`
# argtype means "this function takes no arguments" (matches `compile_and_call`'s
# `argtypes::Type{<:Tuple}` convention, where `Tuple{}` = empty arg list).
_norm_nargs(argtypes) = (length(argtypes) == 1 && argtypes[1] === Tuple{}) ? 0 : length(argtypes)

function native_callable(comp::NativeCompilation, rettype, argtypes::Type...)
    ptr = comp.entry_ptr
    # AT = declared arg-type tuple (Tuple{} for the 0-arg case, incl. the
    # `(Tuple{},)` convention). One uniform closure dispatches via _gcall for any N.
    AT = _norm_nargs(argtypes) == 0 ? Tuple{} : Tuple{argtypes...}
    return ((args...) -> _gcall(ptr, rettype, AT, args...))
end

# Direct .so loading from Julia (no Rust needed for testing)
function native_callable_from_so(comp::NativeCompilation, rettype::Type, argtypes::Type...)
    lib = Libdl.dlopen(comp.so_path)
    func_ptr = Libdl.dlsym(lib, comp.func_name)

    # AT = declared arg-type tuple (Tuple{} for the 0-arg case). One uniform
    # closure dispatches via _gcall for any N. (lib must stay open for the
    # closure's lifetime.)
    AT = _norm_nargs(argtypes) == 0 ? Tuple{} : Tuple{argtypes...}
    return ((args...) -> _gcall(func_ptr, rettype, AT, args...))
end

# Helper function to compile and call directly (handles object returns properly).
# Routes through the N-arg _gcall dispatcher — supports any arity, and calls the
# compiled function exactly once (no double-call, so side-effecting callees like
# push!/pop!/resize!/append! are safe).
function compile_and_call(f, rettype::Type, argtypes::Type{<:Tuple}, args...; name::String="entry")
    comp = compile_native(f, argtypes; name=name)
    lib = Libdl.dlopen(comp.so_path)
    func = Libdl.dlsym(lib, comp.func_name)
    result = _gcall(func, rettype, argtypes, args...)
    Libdl.dlclose(lib)
    rm(comp.so_path)
    return result
end

export compile_native, native_callable, native_callable_from_so, compile_and_call, NativeCompilation, CompileError

end # module NativeCodegen
