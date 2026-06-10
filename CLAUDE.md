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

- `Wasmtime_jll` (Yggdrasil PR 13929, merged 2026-06-09) was not yet in the
  General registry as of 2026-06-10. When it registers: add it as a
  WasmtimeRunner dependency (the `_find_libwasmtime` fallback chain already
  prefers it) and drop the vendored-tarball requirement.
- Next compiler layers, in rough order: `Memory{T}`/`MemoryRef` →  GC arrays
  (unlocks Vector/String), wasm-EH for try/catch, structured relooping to
  replace the dispatcher loop, dynamic dispatch via funcref tables.
