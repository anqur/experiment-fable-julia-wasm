# debug_minimal.jl — Minimal test to verify native compilation infrastructure
using NativeCodegen
import Base.JuliaSyntax as JS

println("=== Minimal Native Test ===")

# Test 1: Simple integer arithmetic
f_add(x::Int64) = x + 1
try
    comp = compile_native(f_add, Tuple{Int64}; name="add_one")
    nf = native_callable_from_so(comp, Int64, Tuple{Int64})
    result = nf(5)
    rm(comp.so_path)
    println("✅ Simple arithmetic: host=6 native=$result")
catch e
    println("❌ Simple arithmetic failed: $e")
end

# Test 2: Create ParseStream
f_create_stream() = JS.ParseStream("1 + 2")
try
    comp = compile_native(f_create_stream, Tuple{}; name="create_stream")
    nf = native_callable_from_so(comp, Any, Tuple{})
    result = nf()
    rm(comp.so_path)
    println("✅ Create ParseStream: returned $result")
catch e
    println("❌ Create ParseStream failed: $e")
end

# Test 3: Read next_byte from ParseStream
f_read_nb(s::JS.ParseStream) = Int64(s.next_byte)
try
    ps = JS.ParseStream("1 + 2")
    comp = compile_native(f_read_nb, Tuple{JS.ParseStream}; name="read_next_byte")
    nf = native_callable_from_so(comp, Int64, Tuple{JS.ParseStream})
    result = nf(ps)
    rm(comp.so_path)
    println("✅ Read next_byte: host=1 native=$result")
catch e
    println("❌ Read next_byte failed: $e")
end

println("=== End Minimal Test ===")
