// GC allocator — Boehm GC with Julia-compatible object layout.

use std::alloc::{GlobalAlloc, Layout};
use bdwgc_alloc::Allocator;

// Julia-compatible object header: starts with type pointer (jl_datatype_t*)
// Julia's jl_value_t structure: type pointer followed by data
#[repr(C)]
pub struct JuliaGCHeader {
    pub type_ptr: *mut u8,  // Pointer to Julia jl_datatype_t
}

// Legacy header for backwards compatibility (will be deprecated)
#[repr(C)]
pub struct GCHeader {
    pub type_tag: u32,
    pub flags: u32,
    pub length: i32,
}

pub const HEADER_SIZE: usize = std::mem::size_of::<GCHeader>();
pub const JULIA_HEADER_SIZE: usize = std::mem::size_of::<JuliaGCHeader>();

// Global GC allocator
#[global_allocator]
pub static GC_ALLOC: Allocator = Allocator;

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc(type_tag: u32, data_size: u32) -> *mut u8 {
    let total = HEADER_SIZE + data_size as usize;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if ptr.is_null() { return std::ptr::null_mut(); }
    let h = ptr as *mut GCHeader;
    (*h).type_tag = type_tag;
    (*h).flags = 0;
    (*h).length = 0;
    ptr.add(HEADER_SIZE)
}

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc_array(
    type_tag: u32, length: i32, elem_size: u32,
) -> *mut u8 {
    let data_size = (length as usize) * (elem_size as usize);
    let total = HEADER_SIZE + data_size;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if ptr.is_null() { return std::ptr::null_mut(); }
    let h = ptr as *mut GCHeader;
    (*h).type_tag = type_tag;
    (*h).flags = 0;
    (*h).length = length;
    ptr.add(HEADER_SIZE)
}

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_array_len(ptr: *const u8) -> i32 {
    if ptr.is_null() { 0 } else { (*(ptr.sub(HEADER_SIZE) as *const GCHeader)).length }
}

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_type_tag(ptr: *const u8) -> u32 {
    if ptr.is_null() { 0 } else { (*(ptr.sub(HEADER_SIZE) as *const GCHeader)).type_tag }
}

// Array operations (Phase 3)

/// Get array element pointer for indexing
#[no_mangle]
pub unsafe extern "C" fn __jl_array_elem_ptr(arr: *const u8, idx: i32, elem_size: u32) -> *mut u8 {
    if arr.is_null() || idx < 0 {
        return std::ptr::null_mut();
    }
    let len = __jl_gc_array_len(arr);
    if idx >= len {
        return std::ptr::null_mut();
    }
    arr.add((idx as usize) * (elem_size as usize)) as *mut u8
}

/// Set array element (for generic arrays)
#[no_mangle]
pub unsafe extern "C" fn __jl_array_set(arr: *mut u8, idx: i32, val: *const u8, elem_size: u32) {
    if arr.is_null() || idx < 0 || val.is_null() {
        return;
    }
    let len = __jl_gc_array_len(arr);
    if idx >= len {
        return;
    }
    let target = arr.add((idx as usize) * (elem_size as usize));
    std::ptr::copy_nonoverlapping(val, target, elem_size as usize);
}

/// Get array element (for generic arrays)
#[no_mangle]
pub unsafe extern "C" fn __jl_array_get(arr: *const u8, idx: i32, elem_size: u32) -> *mut u8 {
    if arr.is_null() || idx < 0 {
        return std::ptr::null_mut();
    }
    let len = __jl_gc_array_len(arr);
    if idx >= len {
        return std::ptr::null_mut();
    }
    // Return pointer to the element (caller is responsible for copying)
    (arr.add((idx as usize) * (elem_size as usize))) as *mut u8
}

// === String operations (Julia-compatible) ===

/// Get Julia type pointer from object allocated with __jl_gc_alloc_julia
#[no_mangle]
pub unsafe extern "C" fn __jl_get_julia_type_ptr(ptr: *const u8) -> *mut u8 {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // The type pointer is located HEADER_SIZE bytes before the data pointer
    let header_ptr = ptr.sub(JULIA_HEADER_SIZE) as *const JuliaGCHeader;
    (*header_ptr).type_ptr
}

// === Julia-compatible allocation functions ===

/// Allocate object with Julia-compatible jl_value_t header
/// This matches Julia's object layout so objects can be safely returned to Julia
#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc_julia(
    type_ptr: *mut u8,  // Julia datatype pointer (jl_datatype_t*)
    data_size: u32,
) -> *mut u8 {
    let total = JULIA_HEADER_SIZE + data_size as usize;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if ptr.is_null() { return std::ptr::null_mut(); }

    // Set Julia type pointer at start (Julia expects this)
    let h = ptr as *mut JuliaGCHeader;
    (*h).type_ptr = type_ptr;

    // Return pointer to data after type pointer
    ptr.add(JULIA_HEADER_SIZE)
}

/// Allocate array with Julia-compatible layout
#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc_array_julia(
    type_ptr: *mut u8,  // Julia datatype pointer
    length: i32,
    elem_size: u32,
) -> *mut u8 {
    let data_size = (length as usize) * (elem_size as usize);
    let total = JULIA_HEADER_SIZE + data_size;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if ptr.is_null() { return std::ptr::null_mut(); }

    // Set Julia type pointer at start
    let h = ptr as *mut JuliaGCHeader;
    (*h).type_ptr = type_ptr;

    // Return pointer to data after type pointer
    let data_ptr = ptr.add(JULIA_HEADER_SIZE);

    // Store length in first sizeof(i32) bytes of data (Julia array convention)
    let len_ptr = data_ptr as *mut i32;
    *len_ptr = length;

    // Return pointer to element data after length field
    data_ptr.add(std::mem::size_of::<i32>())
}

/// Get Julia type pointer from object allocated with __jl_gc_alloc_julia
#[no_mangle]
pub unsafe extern "C" fn __jl_gc_get_julia_type_ptr(ptr: *const u8) -> *mut u8 {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // The type pointer is located HEADER_SIZE bytes before the data pointer
    let header_ptr = ptr.sub(JULIA_HEADER_SIZE) as *const JuliaGCHeader;
    (*header_ptr).type_ptr
}

// === Real Julia array allocation ===
//
// Returning a *fresh* array to Julia requires a real `jl_array_t` object: the
// fake `[type_ptr][len][data]` layout produced by __jl_gc_alloc_array_julia
// does not match Julia's array internals, so indexing the returned object would
// read garbage. Julia's own allocator produces a correct, GC-tracked array that
// `unsafe_pointer_to_objref` can hand back. The symbol resolves against
// libjulia at .so load time (Julia exports its symbols globally).
extern "C" {
    fn jl_alloc_array_1d(atype: *mut u8, nel: usize) -> *mut u8;
}

/// Allocate a real 1-d Julia array of the given element type and length.
/// `atype` is the array type as a jl_value_t* (e.g. pointer_from_objref(Vector{Int64})).
#[no_mangle]
pub unsafe extern "C" fn __jl_array_new_1d(atype: *mut u8, nel: i64) -> *mut u8 {
    if atype.is_null() {
        return std::ptr::null_mut();
    }
    jl_alloc_array_1d(atype, nel.max(0) as usize)
}

// === Real Julia array growth/shrink ===
//
// push!/resize! mutate the array in place and may reallocate its data buffer.
// The jl_array_t* itself stays valid (only the buffer moves), and the IR after
// growth re-derives the data pointer via getfield(a,:ref), so this is safe.
// Wrappers return the array pointer so the import has a non-void return type
// (the invoke results are Nothing/unused). Symbols resolve vs libjulia at load.
extern "C" {
    fn jl_array_grow_end(a: *mut u8, inc: usize);
    fn jl_array_del_end(a: *mut u8, dec: usize);
}

/// Read a 1-d array's current length. The length field sits at offset 16 from
/// the past-type-tag pointer (the same place `getfield(a, :size)` loads from —
/// verified by the existing `ar_len` test). `jl_array_len` is not a globally
/// exported symbol, so read the field directly.
#[inline]
unsafe fn array_len(a: *const u8) -> usize {
    *(a.add(16) as *const i64) as usize
}

/// Grow array `a` by `delta` elements at the end (push! / _growend_internal!).
#[no_mangle]
pub unsafe extern "C" fn __jl_array_grow_end(a: *mut u8, delta: i64) -> *mut u8 {
    if !a.is_null() && delta > 0 {
        jl_array_grow_end(a, delta as usize);
    }
    a
}

/// Shrink array `a` by `dec` elements from the end.
#[no_mangle]
pub unsafe extern "C" fn __jl_array_del_end(a: *mut u8, dec: i64) -> *mut u8 {
    if !a.is_null() && dec > 0 {
        jl_array_del_end(a, dec as usize);
    }
    a
}

/// Set array `a` length to `n` (resize!): grow or shrink as needed.
#[no_mangle]
pub unsafe extern "C" fn __jl_array_resize(a: *mut u8, n: i64) -> *mut u8 {
    if a.is_null() {
        return a;
    }
    let cur = array_len(a);
    let n = n.max(0) as usize;
    if n > cur {
        jl_array_grow_end(a, n - cur);
    } else if n < cur {
        jl_array_del_end(a, cur - n);
    }
    a
}

/// Bulk byte copy used by `append!` / `Base.unsafe_copyto!` between two array
/// data regions. `n` is in BYTES (caller multiplies by elem_size). The dst/src
/// pointers are the resolved element addresses from the MemoryRef pipeline
/// (already advanced to the correct 0-based offset). Non-overlapping regions
/// only — matches `unsafe_copyto!` semantics.
#[no_mangle]
pub unsafe extern "C" fn __jl_memcpy(dst: *mut u8, src: *const u8, n: i64) -> *mut u8 {
    if !dst.is_null() && !src.is_null() && n > 0 {
        std::ptr::copy_nonoverlapping(src, dst, n as usize);
    }
    dst
}
