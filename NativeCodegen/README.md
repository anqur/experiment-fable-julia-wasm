# NativeCodegen — Julia → Native Code Compiler (Frontend)

Translates Julia's optimized SSA IR (`IRCode`) to Cranelift CLIF text, then
compiles to native machine code via the `native-backend` Rust crate.

## Prerequisites

- **Julia nightly** (`julia +nightly`). Required because the WasmCodegen
  overlay interpreter uses `Core.Compiler.InferenceCache` which is only
  available in nightly (removed in Julia 1.12 stable, restored later).
- **Rust** 1.80+ (for the `native-backend` crate)

## Setup

```bash
# From the monorepo root
cd experiment-fable-julia-wasm

# Build the Rust backend first
cd native-backend && cargo build && cd ..

# Julia uses the top-level Project.toml which has [sources] for all local packages
julia +nightly --project=.
```

## Quick test

```julia
julia +nightly --project=.

using NativeCodegen

# Compile a simple function
add64(x::Int64, y::Int64) = x + y
comp = compile_native(add64, Tuple{Int64, Int64})
nf = native_callable(comp, Int64, Int64, Int64)
nf(3, 4)  # returns 7

# Struct field access
mutable struct Point; x::Int64; y::Int64; end
get_x(p::Point) = p.x
comp = compile_native(get_x, Tuple{Point})
nf = native_callable(comp, Int64, Point)
nf(Point(42, 7))  # returns 42

# Control flow (if/else)
abs_val(x::Int64) = x < 0 ? -x : x
comp = compile_native(abs_val, Tuple{Int64})
nf = native_callable(comp, Int64, Int64)
nf(-5)  # returns 5

# Loops with phi nodes
sumto(n::Int64) = (s = Int64(0); i = n; while i > 0; s += i; i -= 1; end; s)
comp = compile_native(sumto, Tuple{Int64})
nf = native_callable(comp, Int64, Int64)
nf(5)  # returns 15

# Float arithmetic
fadd(x::Float64, y::Float64) = x + y + 1.0
comp = compile_native(fadd, Tuple{Float64, Float64})
nf = native_callable(comp, Float64, Float64, Float64)
nf(3.0, 4.0)  # returns 8.0
```

## Architecture

```
Julia source
    │
    ▼
WasmInterp (overlay interpreter from WasmCodegen)
    │  replaces pointer-based Base primitives with loop equivalents
    ▼
Julia IRCode (optimized SSA)
    │
    ▼
clif_emit.jl  ─── CLIF text (Cranelift IR)
    │
    ▼ ccall
native-backend.so (Rust)
    │  Cranelift JIT → native x86-64
    ▼
Native callable (via Libdl.dlopen)
```

## Source files

| File | Purpose |
|------|---------|
| `src/NativeCodegen.jl` | Module entry, bridge functions (`compile_native`, `native_callable`), ccall dispatch for Int64/Int32/Float64/Ptr args |
| `src/clif_emit.jl` | CLIF text emitter — intrinsic mapping (Dict-based), getfield/setfield!, CFG basic blocks → CLIF blocks, phi nodes → block params, `brif`/`jump` terminators |
| `src/clif_types.jl` | CLIF type mapping, `CLIFCtx` state, emit helpers |
| `src/interp.jl` | Reuses WasmCodegen's `WasmInterp` overlay interpreter |
| `src/intrinsics.jl` | Intrinsic → CLIF lowering (minimal, most logic in clif_emit.jl) |
| `src/reprs.jl` | Scalar representation mapping (target-agnostic, from WasmCodegen) |
| `test/runtests.jl` | Differential test suite |

## Supported features

| Category | Operations | Examples |
|----------|-----------|----------|
| Int arithmetic | `+`, `-`, `*`, `div`, `rem`, `neg`, `abs` | `add64(3,4)=7` |
| Int bitwise | `&`, `|`, `^`, `~`, `<<`, `>>`, `>>>` | `ispow2(8)=true` |
| Int comparisons | `==`, `!=`, `<`, `<=`, `>`, `>=` | `iseven(4)=true` |
| Float arithmetic | `+`, `-`, `*`, `/`, `neg`, `abs`, `sqrt` | `fadd_f(3,4)=8.0` |
| Float comparisons | `<`, `>`, `==` | `flt(3.0,4.0)=true` |
| Bit ops | `clz`, `ctz`, `popcnt`, `bswap` | `leading_zeros(1)=63` |
| Conversions | `sext`, `zext`, `trunc`, `bitcast` | |
| Struct fields | `getfield`, `setfield!` | `get_x(Pt(42,7))=42` |
| Control flow | `if/else` | `abs(-5)=5` |
| Loops | `while` with phi nodes | `sumto(5)=15`, `gcd(12,8)=4` |
| Return types | `Int64`, `Float64`, `Bool`, `Ptr{Cvoid}` | |

## Known limitations

- **Julia nightly required** — uses `InferenceCache` which was removed in 1.12 stable
- **Flisp parser stack limit** — total `function/if/for/struct` opens across all
  `include()`d files must stay under ~25. This is why `clif_types.jl` is split from
  `clif_emit.jl`, and intrinsics use a Dict instead of an if-elseif chain.
- **Struct construction (`:new`)** not supported — blocked by Cranelift 0.133 JIT
  not allowing `call` to external symbols from CLIF. Struct field access works.
- **Arrays, strings** not yet supported (need `Memory{T}`, `Vector{T}` GC types)
- **Exception handling** not yet supported
- **Checked arithmetic** handled as plain ops (overflow flag ignored)
- **Float32** args not fully wired in bridge (Float64 works)

## Debugging CLIF output

```julia
using NativeCodegen, WasmCodegen
interp = WasmCodegen.WasmInterp()
clif = NativeCodegen.compile_to_clif(interp, f, Tuple{...})
println(clif)
```
