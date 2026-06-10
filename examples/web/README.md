# Julia lexer and parser in the browser

`lexer.wasm` is the actual `JuliaSyntax.Tokenize` lexer, compiled from Julia's
optimized IR by WasmCodegen (no manual port). The page tokenizes as you type,
entirely client-side; unicode classification runs in-wasm (UnicodeNext tables
as wasm GC arrays). The only JS imports are `codeunit`/`ncodeunits` on the
input text, `===` on host constants, and the `emit_token` sink.

`parser.wasm` (parser.html) goes further: the complete `JuliaSyntax.jl`
recursive-descent parser, including its error recovery and token validation,
compiled the same way. The module streams the parser's native event
representation (tokens + tree ranges) through `emit_token`/`emit_node`; the
green parse tree is reconstructed host-side exactly like
`JuliaSyntax.build_tree`. Extra imports beyond the lexer's: the `_hb_*` byte
bridge (wasm-built strings are interned host-side; float literals are parsed
with a strtod emulation incl. hexfloats) and string formatting for diagnostic
messages (`repr`, `print_to_string`).

Serve over HTTP (wasm cannot be fetched from file://):

    cd examples/web && python3 -m http.server 8000
    # open http://localhost:8000             — lexer demo
    # open http://localhost:8000/parser.html — parser demo
    # (Chrome 119+, Firefox 120+, Safari 18.4+)

Rebuild after compiler changes:

    julia --project=/workspace examples/lexer/build_web.jl
    julia --project=/workspace examples/parser/build_web.jl
    node examples/web/test_node.mjs          # headless V8 check (lexer)
    node examples/web/test_parser_node.mjs   # headless V8 check (parser)
