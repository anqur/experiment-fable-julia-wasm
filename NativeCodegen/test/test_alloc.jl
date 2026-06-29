# Test struct allocation — verified with is_pic + Linkage::Import
# Usage: julia +nightly --project=. NativeCodegen/test/test_alloc.jl

using NativeCodegen
using Test

println("=== Struct Allocation ===")

mutable struct Point
    x::Int64
    y::Int64
end

# Test 1: allocate a Point, return pointer
function sf_new(x::Int64, y::Int64)
    return Point(x, y)
end

print("  new_pt ... ")
try
    comp = compile_native(sf_new, Tuple{Int64,Int64}; name="new_pt")
    nf = native_callable_from_so(comp, Point, Int64, Int64)
    ptr = nf(Int64(10), Int64(20))
    pt = unsafe_pointer_to_objref(ptr)::Point
    if pt.x == 10 && pt.y == 20
        println("✅ Point($(pt.x), $(pt.y))")
    else
        println("❌ got ($(pt.x), $(pt.y)), expected (10, 20)")
    end
    rm(comp.so_path)
catch e
    println("❌ $e")
end

# Test 2: allocate, store, read back fields
function sf_new_sum(x::Int64, y::Int64)
    p = Point(x, y)
    return p.x + p.y
end

# Check IR to confirm :new is actually emitted (vs optimized away)
print("  new_sum_ir ... ")
interp = WasmCodegen.WasmInterp()
tt = Base.signature_type(sf_new_sum, Tuple{Int64,Int64})
matches = Base._methods_by_ftype(tt, -1, interp.world)
mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
ir, _ = result[1]
has_new = any(stmt[:stmt] isa Expr && stmt[:stmt].head == :new for stmt in ir.stmts)
if has_new
    println("has :new (will test call)")
    try
        comp = compile_native(sf_new_sum, Tuple{Int64,Int64}; name="new_sum")
        nf = native_callable_from_so(comp, Int64, Int64, Int64)
        r = nf(Int64(7), Int64(8))
        if r == 15
            println("  new_sum ... ✅ $r")
        else
            println("  new_sum ... ❌ got $r, expected 15")
        end
        rm(comp.so_path)
    catch e
        println("  new_sum ... ❌ $e")
    end
else
    println("optimized away (no :new in IR)")
end

# Test 3: allocate array via Vector{Int64}(undef, n), return length
function ar_alloc(n::Int64)
    v = Vector{Int64}(undef, n)
    return length(v)
end

print("  ar_alloc ... ")
try
    comp = compile_native(ar_alloc, Tuple{Int64}; name="ar_alloc")
    nf = native_callable_from_so(comp, Int64, Int64)
    r = nf(Int64(5))
    if r == 5
        println("✅ $r")
    else
        println("❌ got $r, expected 5")
    end
    rm(comp.so_path)
catch e
    println("❌ $e")
end

println("\n=== Done ===")
