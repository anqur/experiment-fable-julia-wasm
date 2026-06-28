// Exception handling — Phase 1: abort, Phase 3: setjmp/longjmp catch frames.

use std::process;

/// Throw an exception. Phase 1: just abort.
/// Phase 3: longjmp to the nearest catch frame.
#[no_mangle]
pub unsafe extern "C" fn __jl_throw() -> ! {
    eprintln!("FATAL: uncaught exception in compiled Julia code");
    process::abort();
}

/// Enter a catch frame. Phase 1: stub (returns 0 = no catch active).
/// Phase 3: setjmp-based implementation.
#[no_mangle]
pub unsafe extern "C" fn __jl_try_enter(_catch_frame: *mut u8) -> i32 {
    0 // Phase 1: never catch
}

/// Exit a catch frame. Phase 1: no-op.
#[no_mangle]
pub unsafe extern "C" fn __jl_try_exit(_catch_frame: *mut u8) {
    // Phase 3: pop catch frame stack
}
