# Explore struct-related IR patterns under WasmInterp
# Usage: julia +nightly --project=. NativeCodegen/test/debug_struct_ir.jl

using WasmCodegen: WasmInterp, scalar_repr
using NativeCodegen

# === Struct definitions ===

mutable struct Point
    x::Int64
    y::Int64
end

struct ImmPair
    a::Int64
    b::Int64
end

# === Helper: inspect IR for a function ===

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
        elseif e isa Core.PiNode
            println("       PiNode: val=$(e.val) type=$(e.typ)")
        elseif e isa Core.PhiNode
            println("       PhiNode: edges=$(e.edges) values=$(e.values)")
        end
    end
    println()
    return ir, rettype
end

# === 1. Mutable struct getfield ===

println("="^60)
println("1. get_x(p::Point) — mutable struct getfield")
println("="^60)

function get_x(p::Point)
    return p.x
end
inspect_ir(get_x, Tuple{Point})

# === 2. Mutable struct setfield ===

println("="^60)
println("2. set_x(p::Point, v) — mutable struct setfield")
println("="^60)

function set_x(p::Point, v::Int64)
    p.x = v
    return p
end
inspect_ir(set_x, Tuple{Point, Int64})

# === 3. Immutable struct getfield ===

println("="^60)
println("3. get_a(p::ImmPair) — immutable struct getfield")
println("="^60)

function get_a(p::ImmPair)
    return p.a
end
inspect_ir(get_a, Tuple{ImmPair})

# === 4. PiNode ===

println("="^60)
println("4. PiNode — type assertion")
println("="^60)

function typed_ret(x::Int64)
    y = x::Int64
    return y
end
inspect_ir(typed_ret, Tuple{Int64})

# === 5. Memory layout verification ===

println("="^60)
println("5. Memory layout: mutable struct")
println("="^60)

p = Point(42, 99)
ptr = pointer_from_objref(p)
println("pointer_from_objref(p): ", ptr)
println("fieldoffset(Point, 1): ", fieldoffset(Point, 1))
println("fieldoffset(Point, 2): ", fieldoffset(Point, 2))
println("sizeof(Point): ", sizeof(Point))

# Verify by reading fields directly
x_ptr = convert(Ptr{Int64}, ptr + fieldoffset(Point, 1))
y_ptr = convert(Ptr{Int64}, ptr + fieldoffset(Point, 2))
println("x from pointer: ", unsafe_load(x_ptr), " (expect ", p.x, ")")
println("y from pointer: ", unsafe_load(y_ptr), " (expect ", p.y, ")")

println()
println("="^60)
println("6. Memory layout: immutable struct")
println("="^60)

ip = ImmPair(10, 20)
println("isbitstype(ImmPair): ", isbitstype(ImmPair))
println("sizeof(ImmPair): ", sizeof(ImmPair))
println("fieldoffset(ImmPair, 1): ", fieldoffset(ImmPair, 1))
println("fieldoffset(ImmPair, 2): ", fieldoffset(ImmPair, 2))
println("Type: scalar_repr(ImmPair) = ", scalar_repr(ImmPair))
println("Type: Base.ismutabletype(ImmPair) = ", Base.ismutabletype(ImmPair))

# For bitstypes, pointer_from_objref errors
println("Immutable structs are bitstypes — pointer_from_objref not applicable")
println("Will need special handling (expand into scalar params or pass by value)")

println()
println("="^60)
println("7. Mixed-type mutable struct")
println("="^60)

mutable struct HasMixed
    a::Int64
    b::Float64
    c::Int32
end

m = HasMixed(1, 2.5, Int32(3))
println("fieldoffset(HasMixed, 1): ", fieldoffset(HasMixed, 1))
println("fieldoffset(HasMixed, 2): ", fieldoffset(HasMixed, 2))
println("fieldoffset(HasMixed, 3): ", fieldoffset(HasMixed, 3))
println("sizeof(HasMixed): ", sizeof(HasMixed))

# Verify reads
ptr_m = pointer_from_objref(m)
a_val = unsafe_load(convert(Ptr{Int64}, ptr_m + fieldoffset(HasMixed, 1)))
b_val = unsafe_load(convert(Ptr{Float64}, ptr_m + fieldoffset(HasMixed, 2)))
c_val = unsafe_load(convert(Ptr{Int32}, ptr_m + fieldoffset(HasMixed, 3)))
println("a (Int64): ", a_val, " (expect ", m.a, ")")
println("b (Float64): ", b_val, " (expect ", m.b, ")")
println("c (Int32): ", c_val, " (expect ", m.c, ")")

println()
println("Done.")
