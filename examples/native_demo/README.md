# native-demo — Rust consumer of compiled Julia .so

Demonstrates loading a compiled Julia `.so` (produced by NativeCodegen +
native-backend) from a Rust binary via `libloading`. No Julia runtime needed
at the consumption site.

## Prerequisites

- Rust 1.80+
- A compiled Julia `.so` produced by NativeCodegen (see below)

## Build

```bash
cd examples/native_demo
cargo build
```

## Usage

First, compile a Julia function to native code:

```julia
julia +nightly --project=../..

using NativeCodegen

# Compile a function
add64(x::Int64, y::Int64) = x + y
comp = compile_native(add64, Tuple{Int64, Int64})

# The native code is already compiled and callable from Julia
nf = native_callable(comp, Int64, Int64, Int64)
nf(3, 4)  # returns 7

# The .so is the native-backend library itself
# The compiled JIT code lives in memory; for a persistent .so,
# see production deployment notes below.
```

Currently the demo loads the `native-backend` shared library and demonstrates
looking up compiled function pointers. For a full deployment scenario where
the compiled Julia code is embedded in a standalone `.so`, see the Phase 4
plan (JuliaSyntax parser → standalone shared library).

## Source

| File | Purpose |
|------|---------|
| `Cargo.toml` | Depends on `libloading` for dynamic `.so` loading |
| `src/main.rs` | Loads `.so`, looks up compiled function, calls it |

## Production deployment (Phase 4+)

The long-term goal is to produce a **standalone `.so`** that contains both the
compiled Julia code AND the Rust runtime, consumable from any language with C FFI:

```
Julia NativeCodegen + native-backend
    │
    ▼
libjuliasyntax_native.so  (standalone, no Julia dep)
    │
    ▼
Rust/C/Python/Zig consumer (via C FFI)
```

This requires embedding the JIT-compiled code into the shared library, which
is deferred to a future phase.
