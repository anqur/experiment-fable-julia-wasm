# Test if we can workaround the call crash by passing function pointers
# Usage: julia +nightly --project=. NativeCodegen/test/debug_call_indirect.jl

using NativeCodegen, Libdl

# Idea: instead of calling __jl_gc_alloc via ObjectModule import,
# pass the function pointer as a parameter and use call_indirect.
# But call_indirect also might not work with ObjectModule...

# Alternative: pre-allocate in Julia and pass to compiled function.
# The compiled function fills the pre-allocated array.

# Let's try this: create a Point-like struct in Julia, pass it to compiled
# code that fills it via stores. This proves stores work from compiled code.
mutable struct IntBox
    val::Int64
end

function fill_box(b::IntBox, v::Int64)
    b.val = v
    return b.val
end

# This uses getfield/setfield! which we know work.
# The pointer comes from Julia (pointer_from_objref).
# If this crashes, then stores to externally-allocated memory also crash.
try
    comp = compile_native(fill_box, Tuple{IntBox, Int64}; name="fill_box")
    nf = native_callable_from_so(comp, Int64, IntBox, Int64)
    box = IntBox(0)
    r = nf(box, Int64(42))
    println("fill_box result: $r, box.val: $(box.val)")
catch e
    println("Error: $e")
end
