# debug_parse_stmts.jl — isolate which parser operation miscompiles at runtime.
#
# Strategy: differential test. Compile tiny wrappers around individual parser
# ops (peek / bump / next_byte / lookahead_index / lexer), run them natively
# and on host, print both. Where they diverge is the miscompilation.

using NativeCodegen
using Libdl
import Base.JuliaSyntax as JS

k2i(k) = Int64(reinterpret(UInt16, k))

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
    ok = (host == native) && !(host isa AbstractString)   # host==native and not an error string
    verbose && println(ok ? "✅ host=$host native=$native" :
                            "❌ host=$host native=$native")
    return ok, host, native
end

println("=== Test 1: ParseStream construction returns a usable stream ===")
# Read next_byte field right after construction. Host: 1.
f_nb(s::JS.ParseStream) = Int64(s.next_byte)
ps = JS.ParseStream("1 + 2")
ok, h, n = try_native("next_byte(read)", f_nb, Int64, Tuple{JS.ParseStream}, ps)

println("\n=== Test 2: peek first token kind ===")
f_peek1(s::JS.ParseStream) = k2i(JS.peek(s))
ok2, h2, n2 = try_native("peek1", f_peek1, Int64, Tuple{JS.ParseStream}, ps)

println("\n=== Test 3: bump advances next_byte ===")
# After one bump of '1' (1 byte), next_byte should go 1 -> 2 (host).
f_bump_nb(s::JS.ParseStream) = begin
    nb0 = Int64(s.next_byte)
    JS.bump(s)
    nb1 = Int64(s.next_byte)
    return (nb0, nb1)
end
ok3, h3, n3 = try_native("bump_nb", f_bump_nb, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps)

println("\n=== Test 4: peek, bump, peek — does kind change? ===")
f_pb(s::JS.ParseStream) = begin
    a = k2i(JS.peek(s))
    JS.bump(s)
    b = k2i(JS.peek(s))
    return (a, b)
end
ok4, h4, n4 = try_native("peek_bump_peek", f_pb, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps)

println("\n=== Test 5: lookahead_index before/after bump ===")
f_li(s::JS.ParseStream) = begin
    li0 = Int64(s.lookahead_index)
    JS.bump(s)
    li1 = Int64(s.lookahead_index)
    return (li0, li1)
end
ok5, h5, n5 = try_native("lookahead_index", f_li, Tuple{Int64,Int64}, Tuple{JS.ParseStream}, ps)

println("\n=== Test 6: length(stream.lookahead) after a peek ===")
f_la(s::JS.ParseStream) = begin
    JS.peek(s)
    return Int64(length(s.lookahead))
end
ok6, h6, n6 = try_native("lookahead_len", f_la, Int64, Tuple{JS.ParseStream}, ps)

println("\n=== Test 7: full from-string parse into count ===")
function parse_count(src::String)
    ps = JS.ParseStream(src)
    JS.parse!(ps)
    return Int64(length(ps.output) - 1)
end
ok7, h7, n7 = try_native("parse_count", parse_count, Int64, Tuple{String}, "1 + 2")

println("\n=== SUMMARY ===")
println("next_byte read:      $(ok  ? "✅" : "❌") ($h vs $n)")
println("peek1:               $(ok2 ? "✅" : "❌") ($h2 vs $n2)")
println("bump advances byte:  $(ok3 ? "✅" : "❌") ($h3 vs $n3)")
println("peek-bump-peek:      $(ok4 ? "✅" : "❌") ($h4 vs $n4)")
println("lookahead_index:     $(ok5 ? "✅" : "❌") ($h5 vs $n5)")
println("lookahead length:    $(ok6 ? "✅" : "❌") ($h6 vs $n6)")
println("parse_count full:    $(ok7 ? "✅" : "❌") ($h7 vs $n7)")
