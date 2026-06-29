// String operations — Phase 2: implementation.

const STRING_TYPE_TAG: u32 = 1;

/// Create a GC-managed string from UTF-8 bytes.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_new(data: *const u8, len: i32) -> *mut u8 {
    if data.is_null() || len < 0 {
        return std::ptr::null_mut();
    }

    // Call the GC allocation function with STRING_TYPE_TAG
    let ptr = crate::runtime::gc::__jl_gc_alloc_array(STRING_TYPE_TAG, len, 1);
    if ptr.is_null() {
        return std::ptr::null_mut();
    }

    // Copy the string data
    std::ptr::copy_nonoverlapping(data, ptr, len as usize);
    ptr
}

/// Get the length (code units) of a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_len(s: *const u8) -> i32 {
    if s.is_null() {
        return 0;
    }
    crate::runtime::gc::__jl_gc_array_len(s)
}

/// Get a byte from a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_get(s: *const u8, idx: i32) -> u8 {
    if s.is_null() || idx < 0 {
        return 0;
    }
    let len = __jl_string_len(s);
    if idx >= len {
        return 0;
    }
    *s.add(idx as usize)
}

/// Set a byte in a GC-managed string.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_set(s: *mut u8, idx: i32, b: u8) {
    if s.is_null() || idx < 0 {
        return;
    }
    let len = __jl_string_len(s);
    if idx >= len {
        return;
    }
    *s.add(idx as usize) = b;
}

/// Create a string from a C string (null-terminated).
#[no_mangle]
pub unsafe extern "C" fn __jl_string_from_cstr(cstr: *const i8) -> *mut u8 {
    if cstr.is_null() {
        return __jl_string_new(std::ptr::null(), 0);
    }

    let mut len: i32 = 0;
    while *cstr.add(len as usize) != 0 {
        len += 1;
    }

    __jl_string_new(cstr as *const u8, len)
}

/// Get a codeunit (byte) from a string - Julia 1-based indexing.
/// This is the implementation of Julia's codeunit(s::String, i::Int) function.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_codeunit(s: *const u8, idx: i64) -> u8 {
    if s.is_null() || idx < 1 {
        return 0;
    }
    let zero_based_idx = idx - 1;
    __jl_string_get(s, zero_based_idx as i32)
}
