using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, Kind
import Base.JuliaSyntax: parse_resword, parse_atom, parse_call, parse_eq,
                        parse_docstring, parse_public, parse_stmts, parse_toplevel

kinds_of(out) = Int64[reinterpret(UInt16, JuliaSyntax.kind(getfield(out[i], :head))) for i in 1:length(out)]

# Layer 0: direct parse_block (known to work)
import Base.JuliaSyntax: parse_unary_prefix, parse_block
function L0_block(src)
    s = ParseStream(src); ps = ParseState(s)
    bump(ps, Base.JuliaSyntax.TRIVIA_FLAG); bump_invisible(ps, Kind(0))
    parse_unary_prefix(ps); parse_block(ps, parse_public)
    return kinds_of(s.output)
end
# Layer 1: via parse_resword
function L1_resword(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_resword(ps)
    return kinds_of(s.output)
end
# Layer 2: via parse_atom
function L2_atom(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_atom(ps)
    return kinds_of(s.output)
end
# Layer 3: via parse_eq -> ... -> atom
function L3_eq(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_eq(ps)
    return kinds_of(s.output)
end
# Layer 4: via parse_public (-> docstring -> eq)
function L4_public(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_public(ps)
    return kinds_of(s.output)
end
# Layer 5: via parse_stmts
function L5_stmts(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_stmts(ps)
    return kinds_of(s.output)
end
# Layer 6: via parse_toplevel (the real entry)
function L6_toplevel(src)
    s = ParseStream(src); ps = ParseState(s)
    parse_toplevel(ps)
    return kinds_of(s.output)
end

using Base.JuliaSyntax: bump, bump_invisible, TRIVIA_FLAG
srcs = ("module A end", "module A\nend")
for (name, f) in (("L0_block", L0_block), ("L1_resword", L1_resword), ("L2_atom", L2_atom),
                  ("L3_eq", L3_eq), ("L4_public", L4_public), ("L5_stmts", L5_stmts),
                  ("L6_toplevel", L6_toplevel))
    println("=== ", name, " ===")
    for src in srcs
        h = f(src)
        println("  src=", repr(src), "  host n=", length(h), " kinds=", h)
    end
end
flush(stdout)

println("\n--- native vs host (looking for first layer where newline mismatches) ---")
for (name, f) in (("L1_resword", L1_resword), ("L2_atom", L2_atom), ("L3_eq", L3_eq),
                  ("L4_public", L4_public), ("L5_stmts", L5_stmts), ("L6_toplevel", L6_toplevel))
    c = compile_native(f, Tuple{String}; name=name)
    nf = native_callable_from_so(c, Vector{Int64}, String)
    for src in srcs
        n = nf(src); h = f(src)
        status = n == h ? "OK" : "MISMATCH"
        println("  ", name, "  src=", repr(src), "  native_n=$(length(n)) host_n=$(length(h))  ", status)
    end
    rm(c.so_path)
end
