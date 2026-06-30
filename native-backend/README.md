# native-backend — Cranelift JIT + Rust Runtime

Compiles Cranelift CLIF text to native x86-64 machine code via the Cranelift
JIT engine (v0.133). Produces a static library (`libnative_backend.a`) with
Boehm GC, exception handling (setjmp/longjmp), and string/array runtime support.

**Note:** The `crate-type` is currently `"staticlib"`. If the Julia
`NativeCodegen` package needs to `dlopen` this at runtime, change
`Cargo.toml` back to `crate-type = ["cdylib"]` and update
`_native_backend_lib()` in `NativeCodegen/src/NativeCodegen.jl`.

## Prerequisites

- **Rust** 1.80+ (tested with 1.94.0)
- macOS (ARM64) or Linux (x86-64). Cranelift auto-detects the host ISA.
- **Boehm GC** — pulled automatically via `bdwgc-alloc` crate.

## Build

Use the **dev profile for local development** — it rebuilds in ~0.3s vs ~60s for
release (release sets `lto = true` + `opt-level = 3`, which dominates compile
time over the large Cranelift graph). Release is only needed for runtime-perf
measurements. `[profile.dev]` disables `debug-assertions` because
cranelift-frontend's empty-`FunctionBuilderContext` assertion doesn't fit our
transient-builder pattern; codegen is correct either way (verified by the test
suite).

```bash
cd native-backend
cargo build            # dev build → target/debug/libnative_backend.a  (fast; recommended)
cargo build --release  # release build → target/release/libnative_backend.a  (~1 min)
```

The Julia loader auto-selects the **newest** artifact by mtime across
`target/debug` and `target/release`, so whichever you built last is what runs.

## C ABI exports

The shared library exports these symbols (verify with `nm -gU`):

| Symbol | Signature | Purpose |
|--------|-----------|---------|
| `native_compile` | `(clif_text: *const c_char, len: usize) -> *mut CompiledModule` | Parse CLIF text, JIT-compile all functions |
| `native_lookup` | `(module: *const CompiledModule, name: *const c_char) -> *const u8` | Get function pointer by name |
| `native_free` | `(module: *mut CompiledModule)` | Free compiled module |
| `__jl_gc_alloc` | `(type_tag: u32, data_size: u32) -> *mut u8` | Allocate GC-managed object (malloc-based) |
| `__jl_gc_alloc_array` | `(type_tag: u32, length: i32, elem_size: u32) -> *mut u8` | Allocate GC-managed array |
| `__jl_gc_array_len` | `(ptr: *const u8) -> i32` | Get array length |
| `__jl_gc_type_tag` | `(ptr: *const u8) -> u32` | Get object type tag |
| `__jl_throw` | `() -> !` | Exception throw (Phase 1: aborts) |
| `__jl_try_enter` | `(frame: *mut u8) -> i32` | Enter catch frame (Phase 3 stub) |
| `__jl_try_exit` | `(frame: *mut u8)` | Exit catch frame (Phase 3 stub) |
| `__jl_string_new/len/get/set` | various | String ops (Phase 2 stubs) |
| `__jl_register_offload` | `(idx: i32, func: Option<fn()>)` | Register offload callback |
| `__jl_offload_call` | `(idx: i32)` | Call offload function |

## Architecture

```
Julia (NativeCodegen)
    │
    │ ccall("native_compile", clif_text)
    ▼
┌─────────────────────────────────────────┐
│ compile.rs                               │
│   parse_functions(clif_text)  → Vec<Function>  │
│   JITModule::new(JITBuilder)             │
│   declare_function() + define_function() │
│   finalize_definitions()                 │
│   get_finalized_function() → fn ptr     │
└─────────────────────────────────────────┘
    │
    ▼
Cranelift JIT (cranelift-codegen 0.133)
    │
    ▼
Native x86-64 machine code (mmap'd executable memory)
```

## Source files

| File | Purpose |
|------|---------|
| `Cargo.toml` | Dependencies: cranelift 0.133, cranelift-jit, cranelift-reader, cranelift-module, libc, libloading |
| `src/lib.rs` | Module declarations, re-exports |
| `src/compile.rs` | Core compiler: parse CLIF → Cranelift JIT → fn pointers. Registers runtime symbols in JIT symbol table. |
| `src/types.rs` | GC type descriptors (`GCTypeInfo`, `FieldDesc`) |
| `src/runtime/mod.rs` | Runtime module declarations |
| `src/runtime/gc.rs` | GC allocator — malloc-based with `GCHeader` (type_tag, flags, length). Provides `__jl_gc_alloc`, `__jl_gc_alloc_array`, `__jl_gc_array_len`, `__jl_gc_type_tag`. |
| `src/runtime/exceptions.rs` | Exception handling — Phase 1: `abort()`. Phase 3+: setjmp/longjmp catch frames. |
| `src/runtime/strings.rs` | String operations — Phase 2 stubs. |
| `src/runtime/offload.rs` | Offload dispatch table — Phase 3 stubs. |

## Dependencies

```toml
[dependencies]
cranelift-codegen = "0.133"    # Core codegen library
cranelift-frontend = "0.133"   # IR builder (unused but available)
cranelift-jit = "0.133"        # JIT memory management + executable allocation
cranelift-reader = "0.133"     # CLIF text parser
cranelift-module = "0.133"     # Module-level linking and relocation
target-lexicon = "0.12"        # Host triple detection
libc = "0.2"                   # C ABI types
libloading = "0.8"             # Dynamic library loading (for demo)
```

## Known limitations

- **Cranelift 0.133 JIT does not support `call` to external symbols** from CLIF.
  This means the CLIF code cannot call `__jl_gc_alloc` or other runtime functions.
  Workaround: struct allocation is deferred; struct field access uses `load`/`store`
  with pointer arithmetic.
- **`brif` condition type** — the condition must be `i8` (boolean). Integer
  comparisons produce `i8` directly; extended values need `ireduce.i8`.
  Better approach: trace through `not_int` and use raw `icmp` with swapped targets.
- **Boehm GC** integrated via `bdwgc-alloc` crate (global allocator).
- **ARM64** — not tested. Cranelift supports it but the JIT memory management
  may need adjustments for ARM64's different page protection model.

## Verifying

```bash
# Check exports
nm -gU target/debug/libnative_backend.dylib | grep "__jl_\|native_"

# Validate CLIF parsing (via Julia)
julia +nightly --project=.. -e '
using NativeCodegen
add64(x::Int64,y::Int64)=x+y
comp = compile_native(add64, Tuple{Int64,Int64})
println(comp.clif_text)
'
```
