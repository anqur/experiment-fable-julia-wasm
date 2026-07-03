using NativeCodegen
import JuliaSyntax

# Tree setup
tree = JuliaSyntax.parsestmt(JuliaSyntax.GreenNode, "x = a + b * c + 1")
leaf = JuliaSyntax.GreenNode(JuliaSyntax.SyntaxHead(JuliaSyntax.Kind("Identifier"), 0), UInt32(1), nothing)
println("Tree: x = a + b * c + 1 ($(length(JuliaSyntax.children(tree))) children)")
T = typeof(tree)
LT = typeof(leaf)

ok = Ref(0)
fail = Ref(0)

# === Pattern 1: iterate children, check kind ===
function iter_kinds(t::T)
    cs = JuliaSyntax.children(t)
    cs === nothing && return false
    for c in cs
        if reinterpret(UInt16, JuliaSyntax.kind(c)) == UInt16(3)  # Identifier = 3
            return true
        end
    end
    return false
end

print("iter_kinds ... ")
try
    comp = compile_native(iter_kinds, Tuple{T}; name="ik")
    nf = native_callable_from_so(comp, Bool, T)
    host = iter_kinds(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === Pattern 2: children()[i] with head (fixed index) ===
function first_child_head(t::T)
    cs = JuliaSyntax.children(t)
    cs === nothing && return reinterpret(JuliaSyntax.SyntaxHead, UInt32(0))
    return JuliaSyntax.head(cs[1])
end

print("first_child_head ... ")
try
    comp = compile_native(first_child_head, Tuple{T}; name="fch")
    nf = native_callable_from_so(comp, JuliaSyntax.SyntaxHead, T)
    host = first_child_head(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$(reinterpret(UInt32,got)) host=$(reinterpret(UInt32,host)))")) :
                  (fail[] += 1; println("MISMATCH (got=$(got) host=$(host))"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === Pattern 3: count children matching predicate ===
function count_literals(t::T)
    cs = JuliaSyntax.children(t)
    cs === nothing && return 0
    n = 0
    for c in cs
        JuliaSyntax.is_literal(c) && (n += 1)
    end
    return n
end

print("count_literals ... ")
try
    comp = compile_native(count_literals, Tuple{T}; name="cl")
    nf = native_callable_from_so(comp, Int64, T)
    host = count_literals(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === Pattern 4: span difference between children ===
function span_diff(t::T)
    cs = JuliaSyntax.children(t)
    cs === nothing && return UInt32(0)
    n = length(cs)
    n < 2 && return UInt32(0)
    return JuliaSyntax.span(cs[n]) - JuliaSyntax.span(cs[1])
end

print("span_diff ... ")
try
    comp = compile_native(span_diff, Tuple{T}; name="sd")
    nf = native_callable_from_so(comp, UInt32, T)
    host = span_diff(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === Pattern 5: children length check ===
function num_children(t::T)
    cs = JuliaSyntax.children(t)
    cs === nothing && return Int64(0)
    return Int64(length(cs))
end

print("num_children ... ")
try
    comp = compile_native(num_children, Tuple{T}; name="nc")
    nf = native_callable_from_so(comp, Int64, T)
    host = num_children(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === Leaf node test ===
print("leaf_has_children ... ")
try
    function leaf_has_children(t::LT)
        return JuliaSyntax.children(t) !== nothing
    end
    comp = compile_native(leaf_has_children, Tuple{LT}; name="lhc")
    nf = native_callable_from_so(comp, Bool, LT)
    host = leaf_has_children(leaf)
    got = nf(leaf)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === SourceFile arg ===
print("SourceFile arg ... ")
try
    function sf_pass(s::JuliaSyntax.SourceFile)
        return true
    end
    comp = compile_native(sf_pass, Tuple{JuliaSyntax.SourceFile}; name="sf")
    nf = native_callable_from_so(comp, Bool, JuliaSyntax.SourceFile)
    sf = JuliaSyntax.SourceFile("x = 1")
    host = sf_pass(sf)
    got = nf(sf)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === SyntaxHead call_type_flags ===
print("call_type_flags(SyntaxHead) ... ")
try
    sh_infix = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind("call"), JuliaSyntax.INFIX_FLAG)
    fsh(h::typeof(sh_infix)) = JuliaSyntax.call_type_flags(h)
    comp = compile_native(fsh, Tuple{typeof(sh_infix)}; name="ctf")
    nf = native_callable_from_so(comp, JuliaSyntax.RawFlags, typeof(sh_infix))
    host = fsh(sh_infix)
    got = nf(sh_infix)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

# === is_leaf ===
print("is_leaf (internal node) ... ")
try
    function is_leaf(t::T)
        return JuliaSyntax.children(t) === nothing
    end
    comp = compile_native(is_leaf, Tuple{T}; name="il")
    nf = native_callable_from_so(comp, Bool, T)
    host = is_leaf(tree)
    got = nf(tree)
    got == host ? (ok[] += 1; println("OK (got=$got host=$host)")) :
                  (fail[] += 1; println("MISMATCH (got=$got host=$host)"))
    rm(comp.so_path)
catch e
    fail[] += 1; println("FAIL: $(sprint(showerror, e)[1:min(120, end)])")
end

println("\n=== Final Results: $(ok[]) OK, $(fail[]) FAIL ===")
