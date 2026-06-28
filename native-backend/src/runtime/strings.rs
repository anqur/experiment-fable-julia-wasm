// String operations — Phase 2. Phase 1: stubs.

/// Create a GC-managed string from UTF-8 bytes.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_new(_data: *const u8, _len: i32) -> *mut u8 {
    unimplemented!("string_new (Phase 2)")
}

/// Get the length (code units) of a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_len(_s: *const u8) -> i32 {
    unimplemented!("string_len (Phase 2)")
}

/// Get a byte from a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_get(_s: *const u8, _idx: i32) -> u8 {
    unimplemented!("string_get (Phase 2)")
}

/// Set a byte in a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_set(_s: *mut u8, _idx: i32, _b: u8) {
    unimplemented!("string_set (Phase 2)")
}
