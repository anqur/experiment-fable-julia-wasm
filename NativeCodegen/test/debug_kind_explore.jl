# debug_kind_explore.jl (v2) — Explore additional Kind-related functions
# Run: julia +nightly --project=. NativeCodegen/test/debug_kind_explore.jl

using NativeCodegen
using Test
import Base.JuliaSyntax as JuliaSyntax
using JuliaSyntax: Kind

println("=== Kind Function Exploration ===\n")

# Helper to test a Kind->Bool function
function test_kind_pred(name, fn, cases)
    print("  $name ... ")
    try
        comp = compile_native(fn, Tuple{Kind}; name="kf_$name")
        nf = native_callable_from_so(comp, Bool, Kind)
        all_ok = true
        for (kname, expected) in cases
            k = Kind(kname)
            got = nf(k)
            host = fn(k)
            if got != host
                println("\n    MISMATCH $kname: got=$got, host=$host")
                all_ok = false
            end
        end
        if all_ok
            println("OK ($(length(cases)) cases)")
        end
        rm(comp.so_path)
    catch e
        println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
    end
end

# === New tests NOT covered by test_final.jl ===

@testset "New Kind Functions" begin
    println("\n--- New Kind Functions (not in test_final.jl) ---\n")

    # is_block_form — works now
    test_kind_pred("is_block_form", (k) -> JuliaSyntax.is_block_form(k),
        [("for",true), ("if",true), ("while",true), ("block",true),
         ("call",false), ("Identifier",false), ("+",false)])

    # is_reserved_word — works now
    test_kind_pred("is_reserved_word", (k) -> JuliaSyntax.is_reserved_word(k),
        [("for",true), ("if",true), ("end",true), ("function",true),
         ("call",false), ("Identifier",false), ("+",false)])

    # is_syntactic_unary_op — works now (uses KSet macro -> Tuple)
    test_kind_pred("is_syntactic_unary_op", (k) -> JuliaSyntax.is_syntactic_unary_op(k),
        [("&",true), ("::",true), ("\$",true), ("+",false), ("-",false),
         ("call",false), ("Identifier",false)])

    # is_string_macro_suffix — works now
    test_kind_pred("is_string_macro_suffix", (k) -> JuliaSyntax.is_string_macro_suffix(k),
        [("Identifier",true), ("for",true), ("if",true), ("end",true),
         ("+",false), ("call",false)])
end

@testset "Kind Comparison & Construction" begin
    println("\n--- Kind Comparison & Construction (new) ---\n")

    # Kind equality
    print("  Kind(==) ... ")
    try
        f(a::Kind, b::Kind) = a == b
        comp = compile_native(f, Tuple{Kind, Kind}; name="kf_kind_eq")
        nf = native_callable_from_so(comp, Bool, Kind, Kind)
        ok = nf(Kind("+"), Kind("+")) && !nf(Kind("+"), Kind("-"))
        println(ok ? "OK" : "FAIL")
        rm(comp.so_path)
    catch e
        println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
    end

    # Kind inequality
    print("  Kind(!=) ... ")
    try
        f(a::Kind, b::Kind) = a != b
        comp = compile_native(f, Tuple{Kind, Kind}; name="kf_kind_neq")
        nf = native_callable_from_so(comp, Bool, Kind, Kind)
        ok = nf(Kind("+"), Kind("-")) && !nf(Kind("+"), Kind("+"))
        println(ok ? "OK" : "FAIL")
        rm(comp.so_path)
    catch e
        println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
    end

    # isless(Kind, Kind) — additional verification
    print("  isless(Kind, Kind) ... ")
    try
        f(a::Kind, b::Kind) = Base.isless(a, b)
        comp = compile_native(f, Tuple{Kind, Kind}; name="kf_isless_kind")
        nf = native_callable_from_so(comp, Bool, Kind, Kind)
        ok = nf(Kind("+"), Kind("*")) && !nf(Kind("Identifier"), Kind("Identifier"))
        println(ok ? "OK" : "FAIL")
        rm(comp.so_path)
    catch e
        println("FAIL: ", sprint(showerror, e)[1:min(200,end)])
    end
end

@testset "Kind Functions Status" begin
    println("\n--- Kind Functions Status Summary ---\n")

    println("""
    Functions that work now (36 from test_final.jl + 4 new):
    ├── Section 1 (9): is_identifier, is_keyword, is_literal, is_number,
    │                  is_operator, is_error, is_word_operator,
    │                  is_contextual_keyword, is_block_continuation_keyword
    ├── Section 2 (20): is_prec_assignment..is_prec_pipe_gt
    ├── Section 3 (7): is_whitespace, is_string_delim, is_radical_op,
    │                  is_syntactic_operator, is_macro_name, is_syntax_kind,
    │                  is_syntactic_assignment
    └── NEW (4): is_block_form, is_reserved_word, is_syntactic_unary_op,
                 is_string_macro_suffix

    Kind Comparison/Construction (new):
        Kind equality (==), Kind inequality (!=), isless(Kind, Kind)

    Functions that DO NOT work on Kind:
    ├── is_plain_equals(Kind) — SIGILL (calls is_decorated->flags->head chain on Kind)
    ├── is_type_operator(Kind) — calls is_dotted->flags->head chain on Kind
    ├── is_initial_reserved_word (needs ParseState)
    ├── is_closing_token (needs ParseState)
    ├── is_closer_or_newline (needs ParseState)
    ├── is_unary_op — calls head->flags on Kind (no Kind-specific method)
    ├── is_both_unary_and_binary — calls head->flags on Kind (no Kind-specific method)
    └── untokenize — uses string() (Dict lookup) and Set membership (unsupported)

    Regressions identified in test_final.jl:
    ├── is_trivia(SyntaxHead) — verifier error (i32 constant vs i64 in band)
    ├── is_dotted(SyntaxHead) — same
    ├── is_suffixed(SyntaxHead) — same
    ├── is_decorated(SyntaxHead) — same
    ├── is_infix_op_call(SyntaxHead) — same
    ├── is_prefix_call(SyntaxHead) — same
    ├── is_trivia(GreenNode) — same
    ├── is_prefix_call(GreenNode) — same
    └── is_dotted(GreenNode) — same
    Common root cause: constant flag values (1,2,4,8) emitted as i32
    instead of i64 when flags() returns i64.

    Kind construction bug:
    └── Kind(Int32) — verifier error: uextend.i32 on i32 value rejected
        (similar i32/i64 width mismatch)
    """)
end
