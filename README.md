# Julia → WebAssembly (WasmGC backend)

A layered stack for compiling Julia to WebAssembly using wasm's GC proposal,
with wasmtime as the reference execution engine and the browser (V8) as the
ultimate target.

## Packages

| Package | Purpose |
|---|---|
| `WasmTools/` | Pure-Julia reader/writer/manipulator for wasm binaries. Full wasm 3.0 coverage: WasmGC (struct/array/ref types, rec groups, subtyping), function references, tail calls, exception handling, bulk memory, multi-memory, memory64 limits. Byte-stable round trips; fuzzed against `wasm-tools smith`. Zero dependencies. |
| `WasmtimeRunner/` | Embeds [wasmtime](https://wasmtime.dev) v45 via its C API: load/validate/instantiate modules, call exports, define host functions backed by Julia callables, bind arbitrary Julia values into wasm as `externref`. Traps and engine errors surface as Julia exceptions. |
| `WasmCodegen/` | Translator from Julia's optimized SSA IR (`Base.code_ircode`) to wasm. Engine-agnostic (depends only on WasmTools). Calls it cannot translate become *offload imports* — host functions that call back into native Julia, so partial programs run end-to-end while the compiler grows. |

## Quick start

```bash
export JULIA_DEPOT_PATH=/workspace/.julia:$HOME/.julia
julia --project=/workspace            # top-level env devs all three packages
```

```julia
using WasmCodegen, WasmtimeRunner

fib(n::Int64) = n <= 1 ? n : fib(n - 1) + fib(n - 2)
comp = compile_wasm(fib, Tuple{Int64})    # comp.bytes is the wasm binary

eng = Engine(); store = Store(eng)
inst = instantiate(store, CompiledModule(eng, comp.bytes))
inst["fib"](20)                            # 6765, computed inside wasmtime
```

The same bytes run in the browser/Node (V8):

```bash
julia --project=/workspace examples/node_differential.jl   # 3-engine diff test
node examples/run_wasm.mjs /tmp/fib.wasm fib 20
```

## What the compiler supports today

- Int8–64/UInt8–64/Bool/Char/Float32/Float64 scalars (sub-word types carry a
  sign-correct i32 normalization discipline)
- full integer/float arithmetic, comparisons, conversions, bit counting,
  Julia's total shift semantics, checked arithmetic (`Base.checked_*`) with
  exact overflow-flag semantics
- arbitrary control flow via a dispatcher-loop lowering (any CFG, including
  irreducible), SSA phis as parallel copies
- function calls across `:invoke` edges (recursion, mutual recursion)
- **WasmGC**: concrete structs and tuples become GC structs (packed i8/i16
  fields), mutable structs keep identity (`===` is `ref.eq`),
  `Union{Nothing,T}` becomes a nullable ref (`=== nothing` is `ref.is_null`) —
  enough for linked data structures
- **try/catch/finally via wasm-EH**: per-block `try_table` routing to the
  innermost Julia handler; `÷0`, `typemin÷-1`, out-of-bounds, and explicit
  throws are catchable inside `try` (and trap at the equivalent point outside)
- **offloading**: untranslatable callees with scalar signatures become
  `"julia"` imports; `offload_imports(comp)` yields thunks the embedder binds
  (see `WasmCodegen/test/runtests.jl`), letting any frontier of the stack run
  in wasm while the rest stays native — the basis for differential testing

Not yet: binding the caught exception value (`catch e` with `e` used),
exception propagation across compiled-function boundaries, `String` internals
(byte access is pointer-based; needs an AbstractInterpreter overlay — strings
flow as externrefs today), abstract/union fields, dynamic dispatch, closures.

## Testing strategy

Every layer is differentially tested:

1. `WasmTools/test/` — byte-stable round trips, golden binaries, validation by
   `wasm-tools`, decode of foreign binaries; `test/fuzz.jl` runs seeded
   `wasm-tools smith` campaigns.
2. `WasmtimeRunner/test/` — modules built with WasmTools executed in wasmtime:
   traps, multi-value, host functions, externref identity, WasmGC execution.
3. `WasmCodegen/test/` — the differential harness: every corpus function runs
   natively and in wasmtime; values must `isequal`, errors must map to traps.
4. `examples/node_differential.jl` — the same binaries on V8 (browser path).

## Toolchain notes

- `WasmtimeRunner` depends on `Wasmtime_jll` (compat-pinned to v45, matching
  the verified ABI contracts in `src/abi.jl`); `ENV["WASMTIME_LIB"]` overrides.
  `tools/wasmtime-c-api/` keeps the v45 C **headers** for reference/probes.
- `tools/wasm-tools-dist/` — `wasm-tools` 1.251 (validator/printer/fuzzer).
- Run `julia --project=/workspace` for a dev environment with all packages.
