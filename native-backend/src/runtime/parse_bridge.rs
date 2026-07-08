// Parse bridge stubs linked into every .so via libnative_backend.a.
// These provide __native_parse_stream and __native_init_parse_stream symbols
// that forward calls through settable function pointers.  The test harness
// sets these pointers at init time via @cfunction, eliminating the need for
// a separate trampoline .so.  In a standalone Rust demo, the pointers remain
// null and calls trap.

use std::sync::atomic::{AtomicPtr, Ordering};

type ParseStreamFn = unsafe extern "C" fn(*mut std::ffi::c_void);
type InitParseStreamFn = unsafe extern "C" fn(*const u8, usize) -> *mut std::ffi::c_void;

static PARSE_STREAM_PTR: AtomicPtr<()> = AtomicPtr::new(std::ptr::null_mut());
static INIT_PARSE_STREAM_PTR: AtomicPtr<()> = AtomicPtr::new(std::ptr::null_mut());

#[no_mangle]
pub unsafe extern "C" fn __native_parse_stream(ps: *mut std::ffi::c_void) {
    let ptr = PARSE_STREAM_PTR.load(Ordering::Relaxed);
    if !ptr.is_null() {
        let f: ParseStreamFn = std::mem::transmute(ptr);
        f(ps);
    }
}

#[no_mangle]
pub unsafe extern "C" fn __native_init_parse_stream(
    data: *const u8,
    len: usize,
) -> *mut std::ffi::c_void {
    let ptr = INIT_PARSE_STREAM_PTR.load(Ordering::Relaxed);
    if !ptr.is_null() {
        let f: InitParseStreamFn = std::mem::transmute(ptr);
        f(data, len)
    } else {
        std::ptr::null_mut()
    }
}

#[no_mangle]
pub unsafe extern "C" fn __native_set_parse_stream_fn(f: *mut std::ffi::c_void) {
    PARSE_STREAM_PTR.store(f as *mut (), Ordering::Relaxed);
}

#[no_mangle]
pub unsafe extern "C" fn __native_set_init_parse_stream_fn(f: *mut std::ffi::c_void) {
    INIT_PARSE_STREAM_PTR.store(f as *mut (), Ordering::Relaxed);
}
