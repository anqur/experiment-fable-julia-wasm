using NativeCodegen: compile_native, native_callable_from_so
using Base.JuliaSyntax
using Base.JuliaSyntax: ParseStream, ParseState, Kind, TRIVIA_FLAG, EMPTY_FLAGS,
                        bump, bump_invisible, peek, emit, position, bump_closing_token
import Base.JuliaSyntax: parse_unary_prefix, parse_block, parse_public, is_reserved_word,
                         set_numeric_flags

kinds_of(out) = Int64[reinterpret(UInt16, JuliaSyntax.kind(getfield(out[i], :head))) for i in 1:length(out)]

# Baseline: L0 + bump_closing_token + emit  (== module_branch, known GOOD)
function M0(src)
    s = ParseStream(src); ps = ParseState(s); mark = position(ps)
    bump(ps, TRIVIA_FLAG); bump_invisible(ps, K"VERSION")
    parse_unary_prefix(ps); parse_block(ps, parse_public)
    bump_closing_token(ps, K"end"); emit(ps, mark, K"module", EMPTY_FLAGS)
    return kinds_of(s.output)
end
# + is_reserved_word check
function M1(src)
    s = ParseStream(src); ps = ParseState(s); mark = position(ps)
    bump(ps, TRIVIA_FLAG)
    if is_reserved_word(peek(ps)); bump(ps); end
    bump_invisible(ps, K"VERSION")
    parse_unary_prefix(ps); parse_block(ps, parse_public)
    bump_closing_token(ps, K"end"); emit(ps, mark, K"module", EMPTY_FLAGS)
    return kinds_of(s.output)
end
# + version check + set_numeric_flags (the full parse_resword module branch)
function M2(src)
    s = ParseStream(src); ps = ParseState(s); mark = position(ps)
    bump(ps, TRIVIA_FLAG)
    if is_reserved_word(peek(ps))
        bump(ps)
    else
        if ps.stream.version >= (1, 14)
            bump_invisible(ps, K"VERSION", set_numeric_flags(ps.stream.version[2] * 10))
        end
        parse_unary_prefix(ps)
    end
    parse_block(ps, parse_public)
    bump_closing_token(ps, K"end"); emit(ps, mark, K"module", EMPTY_FLAGS)
    return kinds_of(s.output)
end

srcs = ("module A end", "module A\nend")
for (name, f) in (("M0", M0), ("M1", M1), ("M2", M2))
    print(name, " host: ")
    for src in srcs; print(repr(src), "=>", length(f(src)), "  "); end
    println()
end
flush(stdout)
println("--- native ---")
for (name, f) in (("M0", M0), ("M1", M1), ("M2", M2))
    c = compile_native(f, Tuple{String}; name=name)
    nf = native_callable_from_so(c, Vector{Int64}, String)
    for src in srcs
        n = nf(src); h = f(src)
        print("  ", name, " ", repr(src), " native_n=$(length(n)) host_n=$(length(h)) ")
        println(n == h ? "OK" : "MISMATCH")
    end
    rm(c.so_path)
end
