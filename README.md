# Julia → Native Codegen

An ahead-of-time native compiler for Julia: compiles Julia functions through
Cranelift's programmatic eDSL, links them with a pure-Rust runtime, and
produces a **standalone `.so`** — callable from Rust (or any C-FFI consumer)
with zero Julia dependency.

The generated `.so` is self-contained: it carries its own GC arena, type-tag
registry, string/const bytes in `.rodata`, and keyword/operator `Dict` tables
rebuilt at runtime — none of the Julia-heap-pointer immediates that would tether
it to the compiling process.

**Live demo:** the real `Base.JuliaSyntax` parser compiles to a `.so` and runs
from pure Rust, matching the host:

```bash
cargo run -- examples/native_demo -- lib.so "1 + 2"   # → 7  (GreenNode count)
```

## Architecture

```
Julia source
  → NCGInterp (overlay AbstractInterpreter)
  → optimized Julia IRCode
  → NativeCodegen/builder_emit.jl (IRCode → Cranelift eDSL)
  → ccall → native-builder (Rust cdylib)
  → Cranelift ObjectModule → .o
  → Julia's lld + libnative_backend.a → standalone .so
  → Libdl / pure-Rust dlopen → callable
```

## Packages

| Component | Role |
|---|---|
| `NativeCodegen/` | Julia frontend: overlay interpreter, IR→Cranelift emitter, `.so` linkage |
| `native-builder/` | Rust `cdylib`: owns Cranelift `ObjectModule` + `FunctionBuilder`, exposes eDSL emission through FFI |
| `native-backend/` | Rust `staticlib`: pure-Rust GC (bump arena), strings, exceptions, arrays, type-tag registry, const-`Dict`/`Symbol` rebuild |

## Quick start

### Prerequisites

- Julia nightly (`julia +nightly`) — the overlay interpreter needs `Core.Compiler.InferenceCache`
- Rust 1.80+

### Build

```bash
cd native-backend && cargo build && cd ..
cd native-builder  && cargo build && cd ..
```

### Compile and run

```julia
# julia +nightly --project=.
using NativeCodegen

add64(x::Int64, y::Int64) = x + y
comp = compile_native(add64, Tuple{Int64, Int64})
nf = native_callable_from_so(comp, Int64, Int64, Int64)
nf(3, 4)  # → 7
```

### Standalone pure-Rust demo

```bash
# Compile the JuliaSyntax parser to /tmp/ncg_parse.so
julia +nightly --project=. NativeCodegen/test/debug_standalone_parse.jl

# Run from pure Rust — no Julia loaded
cd examples/native_demo && cargo build
cargo run -- /tmp/ncg_parse.so "1 + 2"          # → 7
cargo run -- /tmp/ncg_parse.so "a + b + c + d"  # → 15
```

The demo builds its `String` argument with the `.so`'s own `__jl_string_from_raw`
helper, calls the compiled `parse_into` entry, and prints the GreenNode count.
Zero `jl_` undefined symbols (`nm -u`). The `.so` is a genuine standalone
artifact.

## What the compiler supports

- **All Julia scalars** — sub-word integers with sign-correct i32 discipline,
  `Char` as raw bits, arbitrary primitive types; full arithmetic with Julia's
  exact semantics: total shifts, checked overflow pairs, bit ops, conversions,
  floats.
- **Arbitrary control flow** — dispatcher-loop lowering, any CFG, recursion and
  mutual recursion across `:invoke` edges.
- **Structs, tuples, arrays** — mutable and immutable struct allocation,
  `Memory{T}`/`Vector`, `push!`/`resize!`/`grow`, in-bounds access, `NamedTuple`.
- **Strings** — `codeunit`/`ncodeunits`/`sizeof`/`length`, concatenation, string
  literals via `.rodata` + `__jl_string_from_raw`.
- **Dicts and Symbols** — const `Dict{K,V}` (keyword/precedence tables) rebuilt
  at runtime from `.rodata` slots/keys/vals; `Symbol` interned by name for `===`
  identity.
- **Checked arithmetic** — `checked_sadd_int`/`checked_srem_int`/etc. materialize
  as value+flag pairs; loop-carried `a % b` feeds phi nodes correctly.
- **Overlay interpreter** (`NCGInterp`) — a custom `AbstractInterpreter` replaces
  pointer-based Base primitives with loop implementations before inlining:
  `codeunit`/`ncodeunits`, `fill!`, hash lookup via linear scan, unicode
  classification via vendored UnicodeNext, `memcpy` substitutes.

Not yet: exception handling, `Any`-typed values, dynamic dispatch, closures,
`Union` returns across FFI.

## Standalone `.so` — how it works

The compiler used to bake Julia-heap addresses into `.text` as immediate
constants (`mov x0,#imm; movk; ret`), so the `.so` only worked in the same
Julia process. The fix resolves every value at **runtime inside the `.so`**:

| Value | Runtime mechanism |
|---|---|
| type pointers / `nothing` sentinel | `__jl_type_tag(id)` — `TYPE_TABLE` registry |
| `String` literals | `.rodata` bytes + `__jl_string_from_raw` |
| `Vector{bits}` tables | `.rodata` elements + `__jl_array_alias_rodata` |
| `Dict{K,V}` tables | `.rodata` slots/keys/vals + `__jl_dict_from_rodata` |
| `Symbol` | `.rodata` name + `__jl_intern_symbol` (interned `===`) |
| `>8-byte bitstypes` / `VersionNumber` / `NamedTuple` | `.rodata` bytes + `__jl_bytes_dup` |

Const rebuilds are memoized by `.rodata` address (`RODATA_CACHE`) so each const
is built once per parse, not per use. `__jl_gc_reset` clears the arena and all
caches between inputs.

## Testing

```bash
# Core regression suite (93 ✅ / 0 ❌)
julia +nightly --project=. NativeCodegen/test/test_edsl_approach.jl

# Rust builds
cd native-backend && cargo build
cd native-builder  && cargo build
```
