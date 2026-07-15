# debug_compaction_probe.jl — isolate the compaction bug in __lookahead_index
#
# Bug A: After compaction, lookahead[1] should read old lookahead[delta+1]
# but instead it reads garbage -> SIGSEGV on getfield(tok,:head).
#
# Probe strategy:
# 1. Full parser probe: drive a ParseStream into compaction (>90% fill), read lookahead[1]
# 2. Direct MemoryRef probe: manually compact a Vector{SyntaxToken}, read [1]
# 3. Minimal MemoryRef probe: just test the :ref advancement without nulling

using NativeCodegen
using Libdl
import Base.JuliaSyntax as JS

k2i(k) = Int64(reinterpret(UInt16, k))
tk2i(tk) = k2i(getfield(getfield(tk, :head), :kind))

function try_native(name, f, retT, argT, args...; verbose=true)
    verbose && print("  $name ... ")
    host = try; f(args...); catch e; sprint(showerror, e); end
    native = try
        comp = compile_native(f, argT; name=name)
        nf = native_callable_from_so(comp, retT, argT.parameters...)
        r = nf(args...)
        rm(comp.so_path)
        r
    catch e
        if e isa InterruptException; rethrow(); end
        sprint(showerror, e)
    end
    ok = (host == native) && !(host isa AbstractString)
    verbose && println(ok ? "✅ host=$host native=$native" :
                            "❌ host=$host native=$native")
    return ok, host, native
end

println("=== Probe 1: Direct MemoryRef advancement (no nulling) ===")
# Test: create a Vector{SyntaxToken}, advance its :ref by delta, read element 1
# Expected: after advancing :ref to delta+1, reading [1] gives old [delta+1]
function test_ref_advance()
    # Create a vector with 5 tokens
    tokens = JS.SyntaxToken[]
    for i in 1:5
        push!(tokens, JS.SyntaxToken(JS.SyntaxHead(JS.Kind(i), 0), UInt32(0), UInt32(0), 0))
    end

    # Simulate compaction: delta=2, advance :ref to 3 (delta+1)
    ref = getfield(tokens, :ref)
    delta = 2
    new_ref = Core.memoryrefnew(ref, delta + 1, false)
    setfield!(tokens, :ref, new_ref)

    # After compaction, tokens[1] should be old tokens[3] (kind=3)
    new_ref2 = getfield(tokens, :ref)
    mr = Base.memoryrefnew(new_ref2, 1, false)
    tok = Base.memoryrefget(mr, :not_atomic, false)
    return Int64(getfield(getfield(tok, :head), :kind))
end
ok1, h1, n1 = try_native("ref_advance", test_ref_advance, Int64, Tuple{})
println("    Expected: both host and native return 3 (old tokens[delta+1])")

println("\n=== Probe 2: Full compaction with nulling ===")
# Test: null front elements, set :size, advance :ref, read [1]
function test_full_compaction()
    # Create a vector with 5 tokens
    tokens = JS.SyntaxToken[]
    for i in 1:5
        push!(tokens, JS.SyntaxToken(JS.SyntaxHead(JS.Kind(i), 0), UInt32(0), UInt32(0), 0))
    end

    delta = 2
    # Step 1: null front elements 1..delta
    for i in 1:delta
        ref = getfield(tokens, :ref)
        mr = Core.memoryrefnew(ref, i, false)
        Core.memoryrefunset!(mr, :not_atomic, false)
    end

    # Step 2: update size
    old_len = Int64(length(tokens))
    new_len = old_len - delta
    setfield!(tokens, :size, (new_len,))

    # Step 3: advance :ref to delta+1
    ref = getfield(tokens, :ref)
    new_ref = Core.memoryrefnew(ref, delta + 1, false)
    setfield!(tokens, :ref, new_ref)

    # Step 4: read element 1 (should be old element 3)
    ref2 = getfield(tokens, :ref)
    mr2 = Base.memoryrefnew(ref2, 1, false)
    tok = Base.memoryrefget(mr2, :not_atomic, false)
    return Int64(getfield(getfield(tok, :head), :kind))
end
ok2, h2, n2 = try_native("full_compaction", test_full_compaction, Int64, Tuple{})
println("    Expected: both host and native return 3 (after compaction)")

println("\n=== Probe 3: ParseStream compaction trigger ===")
# Test: drive a ParseStream to trigger compaction, then read lookahead[1]
# Compaction triggers when: lookahead_index - 1 > 0.9 * length(lookahead)
# So we need lookahead_index > 0.9 * length + 1
# For a buffer that starts at length 16, we need lookahead_index > 15.4 → 16
function test_stream_compaction()
    # Create a stream with enough whitespace to fill >90% of lookahead
    # Each whitespace token is 1 char, so " " repeated 15 times gives 15 tokens
    # Then peek 16 times to trigger compaction
    src = " ^" * repeat(" ", 20)
    ps = JS.ParseStream(src)

    # Peek tokens to fill the lookahead buffer
    for i in 1:17
        JS.peek(ps)
    end

    # After compaction, lookahead[1] should be the first non-consumed token
    ref = getfield(ps.lookahead, :ref)
    mr = Base.memoryrefnew(ref, 1, false)
    tok = Base.memoryrefget(mr, :not_atomic, false)
    return Int64(getfield(getfield(tok, :head), :kind))
end
ok3, h3, n3 = try_native("stream_compaction", test_stream_compaction, Int64, Tuple{})
println("    Expected: both host and native return the same token kind")

println("\n=== Probe 4: MemoryRef recipe sanity check ===")
# Test: verify that memoryrefnew's memref_recipes correctly reload the data pointer
function test_recipe_reload()
    # Create a Vector{Int64} (simpler than SyntaxToken)
    vec = Int64[10, 20, 30, 40, 50]

    # Create a MemoryRef to element 2
    ref1 = getfield(vec, :ref)
    mr1 = Core.memoryrefnew(ref1, 2, false)
    val1 = Base.memoryrefget(mr1, :not_atomic, false)

    # Simulate a reallocation (like _growend_internal!)
    # In the real runtime, this would move the data pointer
    # For this test, we just verify the recipe would reload correctly

    # Read element 2 again using the same MemoryRef
    # Bug A: if recipes don't work, this might read stale data
    val2 = Base.memoryrefget(mr1, :not_atomic, false)

    return (val1, val2)
end
ok4, h4, n4 = try_native("recipe_reload", test_recipe_reload, Tuple{Int64,Int64}, Tuple{})
println("    Expected: (20, 20) - same value before/after")

println("\n=== Probe 5: MemoryRef after manual reallocation ===")
# Test: create a MemoryRef, then reallocate the vector, then read through the old ref
function test_after_realloc()
    # Create a Vector{Int64}
    vec = Int64[10, 20, 30, 40, 50]

    # Create a MemoryRef to element 3
    ref = getfield(vec, :ref)
    mr = Core.memoryrefnew(ref, 3, false)

    # Trigger a reallocation by pushing enough elements
    # (the runtime may or may not move the data)
    for i in 6:20
        push!(vec, i * 10)
    end

    # Try to read through the old MemoryRef
    # Bug A: if the data moved and we didn't reload, this reads garbage
    val = Base.memoryrefget(mr, :not_atomic, false)

    return val
end
ok5, h5, n5 = try_native("after_realloc", test_after_realloc, Int64, Tuple{})
println("    Expected: both host and native return 30 (or any valid value)")

println("\n=== SUMMARY ===")
println("Probe 1 (ref advance):         $(ok1 ? "✅" : "❌") ($h1 vs $n1)")
println("Probe 2 (full compaction):     $(ok2 ? "✅" : "❌") ($h2 vs $n2)")
println("Probe 3 (stream compaction):   $(ok3 ? "✅" : "❌") ($h3 vs $n3)")
println("Probe 4 (recipe reload):        $(ok4 ? "✅" : "❌") ($h4 vs $n4)")
println("Probe 5 (after realloc):       $(ok5 ? "✅" : "❌") ($h5 vs $n5)")

# Diagnostic predictions for each suspect from the problem statement:
println("\n=== SUSPECT ANALYSIS ===")
println("If Probe 1 FAILS: setfield!(:ref, new_ref) doesn't store the advanced address")
println("  → Divergence: native returns wrong kind (or garbage)")
println("If Probe 2 FAILS: nulling loop nulls wrong slots OR advancement is wrong")
println("  → Divergence: native returns wrong kind (or garbage)")
println("If Probe 3 FAILS: full ParseStream compaction corrupts the state")
println("  → Divergence: native returns wrong kind (or SIGSEGV)")
println("If Probe 4 FAILS: memref_recipes are broken (but this is unlikely - isolated test)")
println("  → Divergence: native returns (20, WRONG)")
println("If Probe 5 FAILS: memref_recipes don't survive reallocation")
println("  → Divergence: native returns garbage/30 (host depends on whether data moved)")
