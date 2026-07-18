# native-demo — standalone Julia-syntax parser (no Julia runtime)

Loads a `.so` produced by NativeCodegen + native-backend from **pure Rust** — no
Julia runtime loaded — and parses Julia source. The `.so` is fully
self-contained: it carries its own GC arena, type-tag registry, string/const
bytes, and keyword/operator `Dict` tables, so it does **not** depend on the Julia
process that compiled it.

```bash
cargo run -- <path-to-compiled.so> "any julia input"
#   → entry returned: 7        (GreenNode count for "1 + 2")
```

## What "standalone" means here

Earlier the generated `.so` was **not** independent: it baked Julia-heap
addresses into `.text` as immediate constants (`mov x0,#imm; movk; ret`), so it
only worked when `dlopen`'d back into the *same* Julia process that compiled it.
Loading it in pure Rust SIGSEGV'd. `nm -u` showed zero `jl_` symbols — false
assurance (it can't see baked immediates).

The fix resolves every baked value at **runtime inside the `.so`**:

| Value | Mechanism (runtime symbol in `native-backend`) |
|---|---|
| type pointers / `nothing` sentinel | `__jl_type_tag(id)` — a registry; registered to real `pointer_from_objref(T)` in-process, default BSS addresses standalone |
| `String` literals, demo arg | `.rodata` bytes + `__jl_string_from_raw` |
| >8-byte bitstypes (`RawGreenNode`), `VersionNumber`, `NamedTuple` | `.rodata` bytes + `__jl_bytes_dup` |
| `Vector{bits}` const tables | `.rodata` element bytes + `__jl_array_alias_rodata` |
| `Dict{K,V}` keyword/precedence tables | `.rodata` slots/keys/vals + `__jl_dict_from_rodata` (rebuilds the Julia-layout hash table) |
| `Symbol` | `.rodata` name + `__jl_intern_symbol` (stable address per name ⇒ `===`) |
| `DataType` values | `__jl_type_tag(id)` |

The `.so`'s bytes (literals, table data) live in `.rodata`/`.data` carried by the
shared library; object graphs (Dicts, arrays) are rebuilt into the leak-mode bump
arena at runtime.

## Build & run

```bash
cd native-backend && cargo build && cd ..
cd native-builder && cargo build && cd ..

# Compile parse_into(src::String)::Int64 (GreenNode count) to /tmp/ncg_parse.so
julia +nightly --project=. NativeCodegen/test/debug_standalone_parse.jl

# Run from pure Rust (no Julia present):
cd examples/native_demo && cargo run -- /tmp/ncg_parse.so "1 + 2"      # → 7
cargo run -- /tmp/ncg_parse.so "a + b + c + d"                          # → 15
cargo run -- /tmp/ncg_parse.so $'function f(x)\n  return x\nend'        # → 17
```

Results match the Julia host exactly. Call `__jl_gc_reset()` between inputs to
reclaim the leak-mode arena.

## Source

| File | Purpose |
|---|---|
| `Cargo.toml` | `libloading` for dynamic `.so` loading |
| `src/main.rs` | dlopen; build the `String` arg via the `.so`'s own `__jl_string_from_raw`; call `__jl_entry_parse_into`; print the `Int64`; `__jl_gc_reset` |

## How the demo builds the argument

The entry `parse_into(s::String)` expects a Julia-compatible `String`
(`length@0`, `bytes@8`). The demo builds it with the `.so`'s **own** runtime
helper `__jl_string_from_raw(bytes, len)` — no Julia, no hand-written parse
stub.
