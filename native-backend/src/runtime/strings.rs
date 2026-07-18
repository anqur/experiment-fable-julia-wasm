// String operations — pure-Rust, zero libjulia dependency.
//
// Julia String layout (from pointer_from_objref):
//   offset -8: jl_datatype_t* (type tag, 8 bytes)
//   offset  0: length: i64 (ncodeunits, 8 bytes)
//   offset  8: inline char data (null-terminated)
//
// The type tag (pointer_from_objref(String)) is embedded as a constant by the
// compiled code and passed as string_type_ptr.

const STRING_TYPE_TAG: u32 = 1;  // legacy: for __jl_string_new (internal use only)

/// Build a standalone, Julia-compatible String from raw UTF-8 bytes. Used both
/// to intern string literals (whose bytes live in the .so's .rodata, carried via
/// builder_declare_data) AND as the demo entry-point's argument builder. Layout
/// matches compiled readers: [type_ptr(8)][length i64(8)][bytes][nul], data-ptr
/// points at the length field (offset 0 = length, offset 8 = bytes). The type
/// tag is __jl_type_tag(STRING_ID) — registered to the real pointer_from_objref(String)
/// in-process so unsafe_pointer_to_objref works; a runtime default standalone.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_from_raw(data: *const u8, len: i32) -> *mut u8 {
    if data.is_null() || len < 0 {
        return std::ptr::null_mut();
    }
    let n = len as usize;
    let type_ptr = crate::runtime::gc::__jl_type_tag(crate::runtime::gc::STRING_TYPE_ID);
    let s = crate::runtime::gc::rust_alloc_string(n, type_ptr);
    if s.is_null() {
        return std::ptr::null_mut();
    }
    // rust_alloc_string set length@0 and a NUL terminator; copy bytes to offset 8.
    std::ptr::copy_nonoverlapping(data, s.add(8), n);
    s
}

/// Memoized twin of `__jl_string_from_raw` for string LITERALS (whose bytes live
/// in the .so's .rodata): build the String once per parse, keyed by the rodata
/// address, so repeated literal uses share one object. `__jl_string_from_raw`
/// stays non-memoized for the demo's heap-buffer arg (and any caller that reuses
/// buffers), avoiding stale-cache entries.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_cached(data: *const u8, len: i32) -> *mut u8 {
    if data.is_null() || len < 0 {
        return std::ptr::null_mut();
    }
    let key = data as usize;
    crate::runtime::gc::get_or_build_rodata(key, || {
        let n = len as usize;
        let type_ptr = crate::runtime::gc::__jl_type_tag(crate::runtime::gc::STRING_TYPE_ID);
        let s = crate::runtime::gc::rust_alloc_string(n, type_ptr);
        if s.is_null() {
            return std::ptr::null_mut();
        }
        std::ptr::copy_nonoverlapping(data, s.add(8), n);
        s
    })
}

/// Concatenate two Julia Strings into a new String.
/// `a`/`b` are String pointers (past the type tag): length (i64) at offset 0,
/// inline char data at offset 8.  `string_type_ptr` is pointer_from_objref(String),
/// embedded as a constant by the compiled code.
#[no_mangle]
pub unsafe extern "C" fn __jl_string_concat(
    a: *const u8, b: *const u8, string_type_ptr: *mut u8,
) -> *mut u8 {
    if a.is_null() || b.is_null() {
        return std::ptr::null_mut();
    }
    let la = *(a as *const i64) as usize;
    let lb = *(b as *const i64) as usize;
    let r = crate::runtime::gc::rust_alloc_string(la + lb, string_type_ptr);
    if r.is_null() {
        return std::ptr::null_mut();
    }
    // rust_alloc_string sets the length; copy both operands' inline data into r+8.
    std::ptr::copy_nonoverlapping(a.add(8), r.add(8), la);
    std::ptr::copy_nonoverlapping(b.add(8), r.add(8 + la), lb);
    r
}

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
