# Explore array-related IR patterns under WasmInterp
# Usage: julia +nightly --project=. NativeCodegen/test/debug_array_ir.jl

using WasmCodegen: WasmInterp, scalar_repr
using NativeCodegen

# === Helper: inspect IR ===

function inspect_ir(f, argtypes)
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, rettype = result[1]
    println("Return type: ", rettype)
    println("Arg types: ", ir.argtypes)
    for (i, stmt) in enumerate(ir.stmts)
        println("  [$i] $(stmt[:stmt]) :: $(stmt[:type])")
        e = stmt[:stmt]
        if e isa Expr
            println("       head=$(e.head)")
            for (j, a) in enumerate(e.args)
                println("         arg$j: $(a) ($(typeof(a)))")
            end
        elseif e isa Core.PhiNode
            println("       PhiNode: edges=$(e.edges) values=$(e.values)")
        end
    end
    if !isempty(ir.cfg.blocks) && length(ir.cfg.blocks) > 1
        println("CFG blocks: $(length(ir.cfg.blocks))")
    end
    println()
    return ir, rettype
end

# === 1. Array element read: a[i] ===

println("="^60)
println("1. getidx(a::Vector{Int64}, i) — array element read")
println("="^60)

function getidx(a::Vector{Int64}, i::Int64)
    return a[i]
end
inspect_ir(getidx, Tuple{Vector{Int64}, Int64})

# === 2. Array element write: a[i] = v ===

println("="^60)
println("2. setidx(a::Vector{Int64}, i, v) — array element write")
println("="^60)

function setidx(a::Vector{Int64}, i::Int64, v::Int64)
    a[i] = v
    return a[i]
end
inspect_ir(setidx, Tuple{Vector{Int64}, Int64, Int64})

# === 3. Array length: length(a) ===

println("="^60)
println("3. arrlen(a::Vector{Int64}) — array length")
println("="^60)

function arrlen(a::Vector{Int64})
    return length(a)
end
inspect_ir(arrlen, Tuple{Vector{Int64}})

# === 4. Array length: arraylen intrinsic ===

println("="^60)
println("4. arrlen2(a::Vector{Int64}) — Core.arraylen")
println("="^60)

function arrlen2(a::Vector{Int64})
    return Core.arraylen(a)
end
inspect_ir(arrlen2, Tuple{Vector{Int64}})

# === 5. Memory layout: Vector{Int64} ===

println("="^60)
println("5. Memory layout: Vector{Int64}")
println("="^60)

a = Int64[10, 20, 30, 40]
ptr = pointer_from_objref(a)
println("pointer_from_objref(a): ", ptr)
println("Type: ", typeof(a))
println("Base.ismutabletype(Vector{Int64}): ", Base.ismutabletype(Vector{Int64}))

# Check field layout
for fn in fieldnames(Vector{Int64})
    println("  field :$(fn): offset=$(fieldoffset(Vector{Int64}, fn)), type=$(fieldtype(Vector{Int64}, fn))")
end

# Read raw memory to understand the layout
println()
println("Raw memory dump (first 64 bytes):")
for i in 0:7
    vals = [unsafe_load(convert(Ptr{Int64}, ptr + i*8 + j*8)) for j in 0:0]
    print("  +$(lpad(i*8,2)): ")
    for off in 0:7
        b = unsafe_load(convert(Ptr{UInt8}, ptr + i*8 + off))
        print(lpad(string(b, base=16, pad=2), 3), " ")
    end
    # Try as Int64
    i64_val = unsafe_load(convert(Ptr{Int64}, ptr + i*8))
    println("  | Int64: $(i64_val)")
end

# Verify: first field is usually "ref" (the MemoryRef), second is "size" (length)
println()
println("Length via length(a): ", length(a))
println("Elements: ", a)

# === 6. Memory layout: compare with simple mutable struct ===

println()
println("="^60)
println("6. Array field access via pointer arithmetic")
println("="^60)

# The data pointer is typically at fieldoffset 1 (ref/data)
# The length is typically at some offset
# Let's try to read elements from the data pointer

# For Vector{Int64}, the layout is roughly:
# - offset 0: MemoryRef (data pointer + memory info)
# - offset N: length (Int)

# Get the data field
ref_off = fieldoffset(Vector{Int64}, :ref)
println("ref field offset: ", ref_off)
ref_ptr = unsafe_load(convert(Ptr{Ptr{Int64}}, ptr + ref_off))
println("data pointer (ref.ptr): ", ref_ptr)
if ref_ptr != C_NULL
    println("Elements via data pointer: ", [unsafe_load(ref_ptr, i) for i in 1:length(a)])
end

# Get the size field
size_off = fieldoffset(Vector{Int64}, :size)
println("size field offset: ", size_off)
size_val = unsafe_load(convert(Ptr{Int64}, ptr + size_off))
println("size via pointer: ", size_val)
println("length(a): ", length(a))

println()
println("Done.")
