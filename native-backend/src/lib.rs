// native-backend: Rust runtime static library linked into the compiled `.so`
// by Julia's lld. Provides runtime exports (gc, exceptions, strings, offloads).
// The old CLIF-text JIT path (compile.rs) has been removed — the pipeline now
// uses native-builder's Cranelift ObjectModule eDSL.

pub mod runtime;
pub mod types;

/// Initialize the Boehm GC. Must be called before any allocation.
#[no_mangle]
pub unsafe extern "C" fn native_gc_init() {
    // Trigger GC initialization on first allocation
}
