// Exception handling — Phase 4: basic setjmp/longjmp exception handling.

use std::process;
use std::cell::RefCell;

// Define jmp_buf type (size is platform-specific, but we use a buffer large enough)
#[repr(C)]
pub struct JmpBuf {
    // Platform-specific jmp_buf storage
    // For x86_64 Linux, this is typically 8 words
    data: [i64; 8],
}

extern "C" {
    fn setjmp(env: *mut JmpBuf) -> i32;
    fn longjmp(env: *mut JmpBuf, val: i32) -> !;
}

/// Maximum depth of nested try/catch frames
const MAX_CATCH_DEPTH: usize = 16;

thread_local! {
    /// Thread-local catch frame stack
    static CATCH_STACK: RefCell<Vec<*mut JmpBuf>> = RefCell::new(Vec::with_capacity(MAX_CATCH_DEPTH));
}

/// Diagnostic: print an i64 to stderr AND return it unchanged. Returning the
/// value makes calls non-removable by Cranelift's egraph (the result is used by
/// the surrounding computation), so traces placed mid-block survive — unlike a
/// void-returning call whose unused result gets DCE'd/reordered. stderr is
/// unbuffered so the line survives a subsequent SIGILL.
#[no_mangle]
pub unsafe extern "C" fn __jl_dbg_i64(tag: i64, v: i64) -> i64 {
    eprintln!("NCG_DBG tag={} val={} (0x{:016x})", tag, v, v as u64);
    v
}

/// Throw an exception. Longjmp to the nearest catch frame.
#[no_mangle]
pub unsafe extern "C" fn __jl_throw() -> ! {
    CATCH_STACK.with(|stack| {
        let catch_stack = stack.borrow_mut();
        if let Some(&jmp_buf_ptr) = catch_stack.last() {
            drop(catch_stack); // release the borrow before longjmp
            longjmp(jmp_buf_ptr, 1);
        } else {
            eprintln!("FATAL: uncaught exception in compiled Julia code");
            process::abort();
        }
    });
    // This should never be reached due to longjmp or abort
    process::abort();
}

/// Enter a catch frame. Returns 1 if this is the initial entry, 0 if returning from longjmp.
#[no_mangle]
pub unsafe extern "C" fn __jl_try_enter(catch_frame: *mut u8) -> i32 {
    if catch_frame.is_null() {
        return 0;
    }

    let jmp_buf_ptr = catch_frame as *mut JmpBuf;
    let result = setjmp(jmp_buf_ptr);

    if result == 0 {
        // Initial entry - register this catch frame
        CATCH_STACK.with(|stack| {
            let mut catch_stack = stack.borrow_mut();
            if catch_stack.len() < MAX_CATCH_DEPTH {
                catch_stack.push(jmp_buf_ptr);
            } else {
                eprintln!("FATAL: catch frame stack overflow (depth > {})", MAX_CATCH_DEPTH);
                process::abort();
            }
        });
    }

    // result == 0 means initial entry, result == 1 means returning from longjmp
    if result == 0 { 1 } else { 0 }
}

/// Exit a catch frame. Remove from the catch stack.
#[no_mangle]
pub unsafe extern "C" fn __jl_try_exit(catch_frame: *mut u8) {
    if catch_frame.is_null() {
        return;
    }

    let jmp_buf_ptr = catch_frame as *mut JmpBuf;
    CATCH_STACK.with(|stack| {
        let mut catch_stack = stack.borrow_mut();
        if let Some(&top) = catch_stack.last() {
            if top == jmp_buf_ptr {
                catch_stack.pop();
            } else {
                eprintln!("WARNING: catch frame stack mismatch on exit");
            }
        }
    });
}
