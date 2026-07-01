// Integer-to-string formatting for `string(n)` / `string(n, base=…)`.
// Bypasses Julia's IOBuffer/print infrastructure; called directly from the
// `#string#N` invoke handler in emit_invoke.

extern "C" {
    fn jl_alloc_string(n: usize) -> *mut u8;
}

/// Format `n` as a string in the given `base` (2..36). Returns a fresh Julia
/// String (allocated via `jl_alloc_string`, which sets the length field at
/// offset 0). The caller (the emitter's bridge) returns the ptr and Julia
/// reconstructs via `unsafe_pointer_to_objref`.
#[no_mangle]
pub unsafe extern "C" fn __jl_int_to_string(n: i64, base: i32) -> *mut u8 {
    if base < 2 || base > 36 {
        return std::ptr::null_mut();
    }
    // Worst-case: binary needs 64 digits + optional sign.
    let mut buf = [0u8; 65]; // 64 digits + sign + null (null not stored in string)
    let mut pos = 64;        // fill from the right
    // i64::MIN has no positive i64 representation — use i128 to get the real
    // absolute value without overflow.
    let abs = if n < 0 {
        -(n as i128) as u64
    } else {
        n as u64
    };
    let mut rem = abs;
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    // Build digits right-to-left in buf
    loop {
        pos -= 1;
        buf[pos] = digits[(rem % base as u64) as usize];
        rem /= base as u64;
        if rem == 0 { break; }
    }
    if n < 0 { pos -= 1; buf[pos] = b'-'; }
    let len = 64 - pos;
    let s = jl_alloc_string(len);
    if !s.is_null() {
        // jl_alloc_string already set length at offset 0. Copy digits at
        // offset 8, then null-terminate (Julia strings are null-terminated).
        std::ptr::copy_nonoverlapping(buf.as_ptr().add(pos), s.add(8), len);
        *s.add(8 + len) = 0u8;
    }
    s
}
