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
include("clif_types.jl")
include("builder_emit.jl")

# === Bridge: native compilation + FFI ===

struct NativeCompilation
    so_path::String      # Path to generated .so file
    func_name::String    # Function name (e.g., "entry")
end

const _BUILDER_LIB_PATH = Ref{String}()
const _RUNTIME_LIB_PATH = Ref{String}()

function _init_builder_lib()
    isassigned(_BUILDER_LIB_PATH) && return _BUILDER_LIB_PATH[]
    lib_name = Sys.isapple() ? "libnative_builder.dylib" :
               Sys.islinux()  ? "libnative_builder.so" :
               error("unsupported platform")
    dir = joinpath(dirname(@__DIR__), "..", "native-builder", "target")
    for profile in ("release", "debug")
        path = joinpath(dir, profile, lib_name)
        isfile(path) || continue
        _BUILDER_LIB_PATH[] = path
        return path
    end
    error("native-builder library not found. Build with: cd native-builder && cargo build --release")
end

function _init_runtime_lib()
    isassigned(_RUNTIME_LIB_PATH) && return _RUNTIME_LIB_PATH[]
    lib_name = Sys.isapple() ? "libnative_backend.a" :
               Sys.islinux()  ? "libnative_backend.a" :
               error("unsupported platform")
    dir = joinpath(dirname(@__DIR__), "..", "native-backend", "target")
    for profile in ("release", "debug")
        path = joinpath(dir, profile, lib_name)
        isfile(path) || continue
        _RUNTIME_LIB_PATH[] = path
        return path
    end
    error("native-backend runtime library not found. Build with: cd native-backend && cargo build --release")
end

function compile_native(f, argtypes::Type{<:Tuple}; name::String="entry")
    interp = WasmInterp()

    # Generate object file via eDSL builder
    temp_obj = tempname() * ".o"
    emit_function_via_builder(interp, f, argtypes; name=name, output_path=temp_obj)

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

    return NativeCompilation(so_path, name)
end

# Helper: check if return type needs Ptr{Cvoid} (pointer to GC object)
_is_ptr_type(T) = (T isa DataType && (Base.ismutabletype(T) || T === String) && !(T <: Ptr))

# For pointer returns, use Ptr{Cvoid} instead of from_wire
function _ret(ptr, raw, rettype)
    _is_ptr_type(rettype) && return Ptr{Cvoid}(raw)
    rettype === Float64 && return reinterpret(Float64, raw)
    rettype === Float32 && return reinterpret(Float32, Int32(raw))
    return from_wire(rettype, raw)
end

function _call0(ptr::Ptr{Cvoid}, rettype)
    rettype === Nothing && return (ccall(ptr, Cvoid, ()); nothing)
    _is_ptr_type(rettype) && return ccall(ptr, Ptr{Cvoid}, ())
    rettype === Float64 && return ccall(ptr, Float64, ())
    rettype === Float32 && return ccall(ptr, Float32, ())
    return from_wire(rettype, ccall(ptr, Int64, ()))
end

function _call1_i64(ptr::Ptr{Cvoid}, rettype, T1, a1)
    w1 = Int64(to_wire(T1, a1))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int64,), w1); nothing)
    raw = ccall(ptr, Int64, (Int64,), w1)
    return _ret(ptr, raw, rettype)
end

function _call1_f64(ptr::Ptr{Cvoid}, rettype, a1)
    rettype === Nothing && return (ccall(ptr, Cvoid, (Float64,), a1); nothing)
    rettype === Float64 && return ccall(ptr, Float64, (Float64,), a1)
    rettype === Bool && return ccall(ptr, Int32, (Float64,), a1) != 0
    return from_wire(rettype, ccall(ptr, Int64, (Float64,), a1))
end

function _call2_ff(ptr::Ptr{Cvoid}, rettype, a1, a2)
    rettype === Nothing && return (ccall(ptr, Cvoid, (Float64,Float64), a1, a2); nothing)
    rettype === Float64 && return ccall(ptr, Float64, (Float64,Float64), a1, a2)
    rettype === Bool && return ccall(ptr, Int32, (Float64,Float64), a1, a2) != 0
    return from_wire(rettype, ccall(ptr, Int64, (Float64,Float64), a1, a2))
end

function _call2_fi(ptr::Ptr{Cvoid}, rettype, T2, a1, a2, ::Type{Int64})
    w2 = Int64(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Float64,Int64), a1, w2); nothing)
    raw = ccall(ptr, Float64, (Float64,Int64), a1, w2)
    return from_wire(rettype, raw)
end

function _call1_i32(ptr::Ptr{Cvoid}, rettype, T1, a1)
    w1 = Int32(to_wire(T1, a1))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int32,), w1); nothing)
    raw = ccall(ptr, Int64, (Int32,), w1)
    return _ret(ptr, raw, rettype)
end

function _call2_ii(ptr::Ptr{Cvoid}, rettype, T1, T2, a1, a2, ::Type{Int64}, ::Type{Int64})
    w1 = Int64(to_wire(T1, a1)); w2 = Int64(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int64,Int64), w1, w2); nothing)
    raw = ccall(ptr, Int64, (Int64,Int64), w1, w2)
    return _ret(ptr, raw, rettype)
end

function _call2_ij(ptr::Ptr{Cvoid}, rettype, T1, T2, a1, a2, ::Type{Int64}, ::Type{Int32})
    w1 = Int64(to_wire(T1, a1)); w2 = Int32(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int64,Int32), w1, w2); nothing)
    raw = ccall(ptr, Int64, (Int64,Int32), w1, w2)
    return _ret(ptr, raw, rettype)
end

function _call2_ji(ptr::Ptr{Cvoid}, rettype, T1, T2, a1, a2, ::Type{Int32}, ::Type{Int64})
    w1 = Int32(to_wire(T1, a1)); w2 = Int64(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int32,Int64), w1, w2); nothing)
    raw = ccall(ptr, Int64, (Int32,Int64), w1, w2)
    return _ret(ptr, raw, rettype)
end

# Pointer+scalar dispatch: ptr arg is already a Ptr{Cvoid}
function _call2_pi(ptr::Ptr{Cvoid}, rettype, T2, a1::Ptr{Cvoid}, a2, ::Type{Int64})
    w2 = Int64(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Ptr{Cvoid},Int64), a1, w2); nothing)
    raw = ccall(ptr, Int64, (Ptr{Cvoid},Int64), a1, w2)
    return _ret(ptr, raw, rettype)
end

function _call2_jj(ptr::Ptr{Cvoid}, rettype, T1, T2, a1, a2, ::Type{Int32}, ::Type{Int32})
    w1 = Int32(to_wire(T1, a1)); w2 = Int32(to_wire(T2, a2))
    rettype === Nothing && return (ccall(ptr, Cvoid, (Int32,Int32), w1, w2); nothing)
    raw = ccall(ptr, Int64, (Int32,Int32), w1, w2)
    return _ret(ptr, raw, rettype)
end

_is_i64(T) = !_is_ptr_type(T) && scalar_repr(T).bits == 64 && !scalar_repr(T).isfloat
_is_f64(T) = !_is_ptr_type(T) && scalar_repr(T).isfloat && scalar_repr(T).bits == 64
_is_f32(T) = !_is_ptr_type(T) && scalar_repr(T).isfloat && scalar_repr(T).bits == 32

function native_callable(comp::NativeCompilation, rettype, argtypes::Type...)
    ptr = comp.entry_ptr
    nargs = length(argtypes)
    if nargs == 0
        return (() -> _call0(ptr, rettype))
    elseif nargs == 1
        T1 = argtypes[1]
        rt = rettype
        if _is_ptr_type(T1)
            return (a1 -> _ret(ptr, ccall(ptr, Int64, (Ptr{Cvoid},), pointer_from_objref(a1)), rettype))
        end
        if _is_f64(T1) || _is_f32(T1)
            return (a1 -> _call1_f64(ptr, rt, Float64(a1)))
        end
        if _is_i64(T1)
            return (a1 -> _call1_i64(ptr, rt, T1, a1))
        else
            return (a1 -> _call1_i32(ptr, rt, T1, a1))
        end
    elseif nargs == 2
        T1, T2 = argtypes[1], argtypes[2]
        rt = rettype
        if _is_ptr_type(T1) && !_is_ptr_type(T2)
            if _is_i64(T2)
                return ((a1,a2) -> _call2_pi(ptr, rt, T2, pointer_from_objref(a1), a2, Int64))
            else
                return ((a1,a2) -> _call2_pi(ptr, rt, T2, pointer_from_objref(a1), a2, Int32))
            end
        end
        # Float + Float
        if _is_f64(T1) && _is_f64(T2)
            return ((a1,a2) -> _call2_ff(ptr, rt, a1, a2))
        end
        # Float + Int
        if _is_f64(T1) && _is_i64(T2)
            return ((a1,a2) -> _call2_fi(ptr, rt, T2, a1, a2, Int64))
        end
        i641, i642 = _is_i64(T1), _is_i64(T2)
        VT1 = i641 ? Int64 : Int32
        VT2 = i642 ? Int64 : Int32
        if i641 && i642
            return ((a1,a2) -> _call2_ii(ptr, rt, T1, T2, a1, a2, VT1, VT2))
        elseif i641 && !i642
            return ((a1,a2) -> _call2_ij(ptr, rt, T1, T2, a1, a2, VT1, VT2))
        elseif !i641 && i642
            return ((a1,a2) -> _call2_ji(ptr, rt, T1, T2, a1, a2, VT1, VT2))
        else
            return ((a1,a2) -> _call2_jj(ptr, rt, T1, T2, a1, a2, VT1, VT2))
        end
    else
        error("unsupported arg count $nargs for Phase 1")
    end
end

# Direct .so loading from Julia (no Rust needed for testing)
function native_callable_from_so(comp::NativeCompilation, rettype::Type, argtypes::Type...)
    lib = Libdl.dlopen(comp.so_path)
    func_ptr = Libdl.dlsym(lib, comp.func_name)

    nargs = length(argtypes)
    if nargs == 0
        return () -> _call0(func_ptr, rettype)
    elseif nargs == 1
        T1 = argtypes[1]
        rt = rettype
        if _is_ptr_type(T1)
            return (a1 -> _ret(func_ptr, ccall(func_ptr, Int64, (Ptr{Cvoid},), pointer_from_objref(a1)), rettype))
        end
        if _is_f64(T1) || _is_f32(T1)
            return (a1 -> _call1_f64(func_ptr, rt, Float64(a1)))
        end
        if _is_i64(T1)
            return (a1 -> _call1_i64(func_ptr, rt, T1, a1))
        else
            return (a1 -> _call1_i32(func_ptr, rt, T1, a1))
        end
    elseif nargs == 2
        T1, T2 = argtypes[1], argtypes[2]
        rt = rettype
        if _is_ptr_type(T1) && !_is_ptr_type(T2)
            if _is_i64(T2)
                return ((a1,a2) -> _call2_pi(func_ptr, rt, T2, pointer_from_objref(a1), a2, Int64))
            else
                return ((a1,a2) -> _call2_pi(func_ptr, rt, T2, pointer_from_objref(a1), a2, Int32))
            end
        end
        # Float + Float
        if _is_f64(T1) && _is_f64(T2)
            return ((a1,a2) -> _call2_ff(func_ptr, rt, a1, a2))
        end
        # Float + Int
        if _is_f64(T1) && _is_i64(T2)
            return ((a1,a2) -> _call2_fi(func_ptr, rt, T2, a1, a2, Int64))
        end
        i641, i642 = _is_i64(T1), _is_i64(T2)
        VT1 = i641 ? Int64 : Int32
        VT2 = i642 ? Int64 : Int32
        if i641 && i642
            return ((a1,a2) -> _call2_ii(func_ptr, rt, T1, T2, a1, a2, VT1, VT2))
        elseif i641 && !i642
            return ((a1,a2) -> _call2_ij(func_ptr, rt, T1, T2, a1, a2, VT1, VT2))
        elseif !i641 && i642
            return ((a1,a2) -> _call2_ji(func_ptr, rt, T1, T2, a1, a2, VT1, VT2))
        else
            return ((a1,a2) -> _call2_jj(func_ptr, rt, T1, T2, a1, a2, VT1, VT2))
        end
    else
        error("unsupported arg count $nargs for eDSL approach")
    end
end

export compile_native, native_callable, native_callable_from_so, NativeCompilation, CompileError

end # module NativeCodegen
