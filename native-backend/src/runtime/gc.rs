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

// === Pure-Rust Julia-compatible array allocator ===
//
// The .so is a standalone library with ZERO libjulia dependency. All array
// allocation and mutation is implemented here using Boehm GC.  The layout
// matches the Julia-visible fields of jl_array_t (empirically verified via
// NativeCodegen/test/debug_array_layout.jl on Julia nightly 1.14-DEV):
//
//   [type_tag (8)] [data_ptr (+0)] [_unknown (+8)] [length (+16)] [...]
//
// pointer_from_objref returns offset +0 (past the type tag).  sizeof(Vector{T})
// is 24 (= 3 words).  Beyond +24 are internal jl_array_t fields that Julia
// never exposes; we store our own capacity at +24 for arrays we allocate.
//
// For arrays allocated by Julia and passed in as arguments: we cannot safely
// read nalloc (it lives at a version-dependent offset inside jl_array_t).
// Instead we always allocate a fresh data buffer on grow — correct and simple,
// with the old buffer left for Julia's GC to collect.

/// Julia-compatible 1-d array representation.  pointer_from_objref returns
/// &data_ptr — offset 0 of this struct.
#[repr(C)]
pub struct JuliaArrayRepr {
    pub data_ptr: *mut u8,  // offset +0: element buffer
    pub _pad0: i64,         // offset +8: internal (ndims/offset in jl_array_t)
    pub length: i64,        // offset +16: nrows / current element count
    pub capacity: i64,      // offset +24: allocated element count (OUR field)
}

/// Total allocation size for the array struct (excluding element buffer).
pub const ARRAY_REPR_SIZE: usize = std::mem::size_of::<JuliaArrayRepr>();

/// Allocate a standalone Julia-compatible String.
///
/// Layout: [type_ptr (8)] [length: i64 (8)] [char data (n)] [nul (1)]
/// Returns pointer to the length field (= pointer_from_objref(String)).
/// The type_ptr is a `pointer_from_objref(String)` value embedded as a
/// constant by the compiled code — the runtime does not call into libjulia.
pub unsafe fn rust_alloc_string(n: usize, type_ptr: *mut u8) -> *mut u8 {
    let total = JULIA_HEADER_SIZE + 8 + n + 1; // header + i64 length + data + nul
    let layout = Layout::from_size_align(total, 16).unwrap();
    let alloc = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if alloc.is_null() {
        return std::ptr::null_mut();
    }
    // Type tag at alloc+0
    *(alloc as *mut *mut u8) = type_ptr;
    // i64 length at alloc+8 (data pointer points here)
    *(alloc.add(8) as *mut i64) = n as i64;
    // Null terminator at alloc+16+n
    *(alloc.add(16 + n) as *mut u8) = 0;
    // Return data pointer (past type tag, where length field starts)
    alloc.add(8)
}

/// Allocate a 1-d Julia-compatible array.  `atype` is the array type as a
/// jl_value_t* (e.g. pointer_from_objref(Vector{Int64})), embedded as a
/// constant by the compiled code.  `elem_size` is sizeof(eltype(T)).
#[no_mangle]
pub unsafe extern "C" fn __jl_array_new_1d(
    atype: *mut u8, nel: i64, elem_size: i64,
) -> *mut u8 {
    if atype.is_null() || nel < 0 {
        return std::ptr::null_mut();
    }
    let nel = nel.max(0) as usize;
    let elem_size = elem_size.max(1) as usize;

    // Allocate the struct: type tag + JuliaArrayRepr
    let struct_total = JULIA_HEADER_SIZE + ARRAY_REPR_SIZE;
    let struct_layout = Layout::from_size_align(struct_total, 16).unwrap();
    let alloc = GlobalAlloc::alloc(&GC_ALLOC, struct_layout);
    if alloc.is_null() {
        return std::ptr::null_mut();
    }

    // Write type tag
    *(alloc as *mut *mut u8) = atype;

    // Allocate the element buffer (0 bytes is fine for empty arrays)
    let data_bytes = nel * elem_size;
    let data_buf = if data_bytes > 0 {
        let data_layout = Layout::from_size_align(data_bytes, 16).unwrap();
        GlobalAlloc::alloc(&GC_ALLOC, data_layout)
    } else {
        std::ptr::null_mut()
    };
    if data_buf.is_null() && data_bytes > 0 {
        GlobalAlloc::dealloc(&GC_ALLOC, alloc, struct_layout);
        return std::ptr::null_mut();
    }

    // Initialize struct fields (data_ptr is at alloc + JULIA_HEADER_SIZE)
    let arr = alloc.add(JULIA_HEADER_SIZE) as *mut JuliaArrayRepr;
    (*arr).data_ptr = data_buf;
    (*arr)._pad0 = 0;
    (*arr).length = nel as i64;
    (*arr).capacity = nel as i64;

    alloc.add(JULIA_HEADER_SIZE)
}

#[inline]
unsafe fn array_len(a: *const u8) -> usize {
    *(a.add(16) as *const i64) as usize
}

/// Grow array `a` by `delta` elements (push! / _growend_internal!).
/// Reallocates the data buffer if needed.  Works on both our-allocated and
/// Julia-allocated arrays (allocates fresh + copy for unknown-capacity buffers).
#[no_mangle]
pub unsafe extern "C" fn __jl_array_grow_end(
    a: *mut u8, delta: i64, elem_size: i64,
) -> *mut u8 {
    if a.is_null() || delta <= 0 {
        return a;
    }
    let arr = a as *mut JuliaArrayRepr;
    let old_len = (*arr).length;
    let new_len = old_len + delta;
    let elem_size = elem_size as usize;
    let old_bytes = (old_len as usize) * elem_size;
    let new_bytes = (new_len as usize) * elem_size;

    let old_data = (*arr).data_ptr;
    // Allocate fresh buffer and copy — always works regardless of who
    // originally allocated the old buffer (us or Julia's GC).
    let layout = Layout::from_size_align(new_bytes.max(1), 16).unwrap();
    let new_data = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if !new_data.is_null() {
        if old_bytes > 0 && !old_data.is_null() {
            std::ptr::copy_nonoverlapping(old_data, new_data, old_bytes);
        }
        (*arr).data_ptr = new_data;
        (*arr).capacity = new_len as i64;
    }
    // If alloc failed, keep old data and length unchanged (arr stays valid)
    if !(*arr).data_ptr.is_null() {
        (*arr).length = new_len;
    }
    a
}

/// Shrink array `a` by `dec` elements from the end.  Zeroes removed elements
/// for GC safety (so the GC doesn't trace stale references).
#[no_mangle]
pub unsafe extern "C" fn __jl_array_del_end(
    a: *mut u8, dec: i64, elem_size: i64,
) -> *mut u8 {
    if a.is_null() || dec <= 0 {
        return a;
    }
    let arr = a as *mut JuliaArrayRepr;
    let old_len = (*arr).length;
    let dec = dec.min(old_len);
    let new_len = old_len - dec;
    // Zero the removed tail for GC safety
    let zero_start = (new_len as usize) * (elem_size as usize);
    let zero_bytes = (dec as usize) * (elem_size as usize);
    if zero_bytes > 0 {
        let data = (*arr).data_ptr;
        if !data.is_null() {
            std::ptr::write_bytes(data.add(zero_start), 0, zero_bytes);
        }
    }
    (*arr).length = new_len;
    a
}

/// Set array length to `n` (resize!): grow or shrink as needed.
#[no_mangle]
pub unsafe extern "C" fn __jl_array_resize(
    a: *mut u8, n: i64, elem_size: i64,
) -> *mut u8 {
    if a.is_null() {
        return a;
    }
    let cur = array_len(a);
    let n = n.max(0);
    if n > cur as i64 {
        __jl_array_grow_end(a, n - cur as i64, elem_size);
    } else if n < cur as i64 {
        __jl_array_del_end(a, cur as i64 - n, elem_size);
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
