# Julia → WebAssembly (WasmGC backend)

A layered stack for compiling Julia to WebAssembly using wasm's GC proposal,
with wasmtime as the reference execution engine and the browser as the
ultimate target.

**Live demo:** the actual `JuliaSyntax.Tokenize` lexer, compiled from Julia's
optimized IR and lexing as you type, entirely client-side:
**<https://kenoaistaging.github.io/experiment-fable-julia-wasm/>**

## Packages

| Package | Purpose |
|---|---|
| `WasmTools/` | Pure-Julia reader/writer for wasm binaries. Full wasm 3.0: WasmGC (struct/array/ref types, rec groups, subtyping), function references, tail calls, exception handling, bulk memory, multi-memory. Byte-stable round trips; fuzzed against `wasm-tools smith`. Zero dependencies. |
| `WasmtimeRunner/` | Embeds [wasmtime](https://wasmtime.dev) via `Wasmtime_jll` (pinned to v45): load/validate/instantiate modules, call exports, define host functions backed by Julia callables, bind Julia values into wasm as `externref`. Traps and engine errors surface as Julia exceptions. |
| `WasmCodegen/` | Translator from Julia's optimized SSA IR to wasm. Engine-agnostic (depends only on WasmTools + vendored UnicodeNext). Untranslatable callees become *offload imports* — host functions calling back into native Julia — so partial programs run end-to-end while the compiler grows. |

## Quick start

```julia
# julia --project=.   (the top-level environment devs all three packages)
using WasmCodegen, WasmtimeRunner

fib(n::Int64) = n <= 1 ? n : fib(n - 1) + fib(n - 2)
comp = compile_wasm(fib, Tuple{Int64})     # comp.bytes is the wasm binary

eng = Engine(); store = Store(eng)
inst = instantiate(store, CompiledModule(eng, comp.bytes))
inst["fib"](20)                            # 6765, computed inside wasmtime
```

The same bytes run on V8: `julia --project=. examples/node_differential.jl`
checks native Julia, wasmtime, and Node against each other.

## What the compiler supports

- all Julia scalars (sub-word integers with a sign-correct i32 discipline,
  `Char` as raw bits, arbitrary primitive types), full arithmetic with Julia's
  exact semantics: total shifts, checked overflow tuples, bit ops, conversions
- arbitrary control flow (dispatcher-loop lowering, any CFG), recursion and
  mutual recursion across `:invoke` edges
- **WasmGC**: structs/tuples → GC structs (packed i8/i16 fields), mutable
  identity (`===` is `ref.eq`), `Memory{T}`/`Vector` → GC arrays (`push!` and
  `copy` compile with zero offloads), `Union{Nothing,T}` → nullable refs,
  general small unions of concrete types → `anyref` with per-type boxes
- **try/catch/finally via wasm-EH**: per-block `try_table` routed to the
  innermost handler; `÷0`, overflow, bounds errors, and explicit throws are
  catchable inside `try`
- **overlay interpreter**: a custom `AbstractInterpreter` replaces
  pointer-based Base primitives before inlining — `codeunit`/`ncodeunits`
  become host imports, `unsafe_copyto!` becomes `array.copy`, and unicode
  classification (`category_code`, identifier predicates, grapheme breaks)
  compiles in-wasm via vendored [UnicodeNext](https://github.com/c42f/UnicodeNext.jl)
- **host constants**: Symbol/String literals become imported `externref`
  globals; mutable constant tables (`Dict`, `Vector`, `Memory`) materialize as
  wasm globals via a start function, large numeric tables as data segments
- **offloading**: callees with scalar/externref boundaries (including
  `Union{Nothing,scalar}` returns) become `"julia"` imports bound to native
  thunks — `parse`, `string(n, base=16)`, `exp`/`sin`/`log` run with one or
  two leaf offloads

Not yet: binding the caught exception value (`catch e` with `e` used),
exception propagation across compiled-function call boundaries, `Any`-typed
values, dynamic dispatch, closures as values, RadixSort internals (default
`sort!`; `InsertionSort` compiles).

## Showcase: the JuliaSyntax lexer

`examples/lexer/` compiles the real `JuliaSyntax.Tokenize` lexer (no manual
porting) into a 1.1MB module with **four** host imports: source-text byte
access, `===` on host constants, and the token sink. Token streams match the
native lexer exactly across unicode operators, interpolated/triple strings,
all numeric literal forms, and malformed input — verified under wasmtime
(`examples/lexer/run_wasmtime.jl`) and V8 (`examples/web/test_node.mjs`).
Rebuild the web demo with `examples/lexer/build_web.jl`.

## Testing

Differential testing at every layer: `WasmTools` round-trips byte-stably and
is fuzzed against `wasm-tools smith`; `WasmCodegen`'s harness runs every
corpus function natively and in wasmtime (values must `isequal`, Julia
exceptions must become traps/exceptions); `examples/node_differential.jl`
repeats the comparison on V8. Run a package's suite directly:
`julia --project=. WasmCodegen/test/runtests.jl`.

## Toolchain notes

- `Wasmtime_jll` is compat-pinned to v45, matching the ABI contracts verified
  in `WasmtimeRunner/src/abi.jl`; `ENV["WASMTIME_LIB"]` overrides.
- Tests use the `wasm-tools` binary if present at `tools/wasm-tools-dist/`
  (release v1.251.0) and skip external validation otherwise; `tools/` also
  carries the wasmtime v45 C headers for ABI probes (see `CLAUDE.md`).
