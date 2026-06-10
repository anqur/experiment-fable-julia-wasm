# Julia → WasmGC project

Monorepo of three layered Julia packages compiling Julia to WebAssembly-with-GC:
`WasmTools` (binary format), `WasmtimeRunner` (wasmtime C-API execution),
`WasmCodegen` (IRCode → wasm). See README.md for architecture.

## Environment

- Always `export JULIA_DEPOT_PATH=/workspace/.julia:$HOME/.julia` (the sandbox
  resets `$HOME`; the depot in /workspace persists and has everything
  precompiled).
- Top-level dev env: `julia --project=/workspace` (devs all three packages).
- Run tests directly (fast): `julia --project=/workspace <pkg>/test/runtests.jl`.
- External validator: `tools/wasm-tools-dist/wasm-tools` (validate/print/smith/dump).
- Vendored wasmtime C API: `tools/wasmtime-c-api/` (v45.0.1, lib + headers).
  If `tools/` is missing, re-fetch: wasm-tools release v1.251.0 and the
  `wasmtime-v45.0.1-x86_64-linux-c-api.tar.xz` release tarball from GitHub.
- Node 22 is available; `examples/node_differential.jl` runs compiled modules
  on V8 as the browser-path check.

## Conventions

- Correctness bar: *differential testing*. Any codegen change needs corpus
  entries in `WasmCodegen/test/runtests.jl` (`@difftest f Tuple{...} cases`);
  wasm results must `isequal` native results, Julia exceptions must become traps.
- Loud failure beats silent miscompilation: unsupported constructs must throw
  `CompileError`, never emit approximate code.
- `WasmTools` invariant: `encode(decode(bytes))` is byte-identical for
  self-produced binaries; foreign binaries must re-encode to *valid* modules.
- `WasmCodegen` must stay engine-agnostic (no WasmtimeRunner dependency) so the
  browser backend stays viable.
- Sub-word integers (Int8/16, UInt8/16) live in i32: signed values
  sign-extended, unsigned zero-extended; renormalize after arithmetic
  (`emit_norm!`). GC struct fields pack them as i8/i16 instead.

## Pending / watch

- `Wasmtime_jll` v45.0.1 is a hard dependency (compat "45"). NOTE: the
  pkg-server registry snapshot lagged GitHub; the depot uses a Git-cloned
  General registry (`JULIA_PKG_SERVER=""` flavor) — keep that in mind when
  resolving.
- Next compiler layers, in rough order:
  1. **Custom `AbstractInterpreter`** with overlay methods so a small set of
     pointer-based Base primitives (`codeunit(::String,…)`, `pointer`,
     `unsafe_copyto!(::Memory…)`, `MemoryRef.ptr_or_offset` consumers) are
     intercepted *before inlining* and routed to hostcalls / GC-array ops.
     This is what blocks `parse`, full `sort!` (ScratchQuickSort), `push!`.
  2. Exception-value binding (`catch e`): materialize exception objects as
     the tag payload (GC structs / externref via any.convert_extern), and
     propagate exceptions across compiled-function call boundaries.
  3. Structured relooping to replace the dispatcher loop (perf).
  4. Dynamic dispatch via funcref tables.
- Known documented latitudes (not bugs): `muladd` may differ from native fma
  rounding; `unsafe_trunc` saturates deterministically in wasm; `Memory` allocs
  >2^31 elements trap in wasm (32-bit array lengths) where native overcommits.
