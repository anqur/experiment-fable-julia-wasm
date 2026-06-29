// native-backend: C ABI shared library for native Julia code generation.
//
// Provides:
//   native_compile(source: *const c_char, len: usize) -> *mut CompiledModule
//   native_lookup(module: *const CompiledModule, name: *const c_char) -> *const u8
//   native_free(module: *mut CompiledModule)
//
// Plus runtime exports (gc, exceptions, strings, offloads).

pub mod compile;
pub mod runtime;
pub mod types;

/// Initialize the Boehm GC. Call this once at program startup.
/// The GC allocator initializes automatically on first use.
#[no_mangle]
pub unsafe extern "C" fn native_gc_init() {
    // GC allocator is self-initializing
}
