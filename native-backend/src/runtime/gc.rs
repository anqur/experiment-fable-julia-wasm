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

/// Allocate array with Julia-compatible layout.
/// Layout: [type_tag(8)] [length(i64,8)] [element data...]
/// Returns pointer to element data area (past type tag + length field).
/// Memory{Int64} layout (verified via fieldoffset probes):
///   fieldoffset(:length) = 0 (i64, 8 bytes), fieldoffset(:ptr) = 8
#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc_array_julia(
    type_ptr: *mut u8,  // Julia datatype pointer
    length: i32,
    elem_size: u32,
) -> *mut u8 {
    let data_size = (length as usize) * (elem_size as usize);
    // Always include the 8-byte length field in the allocation, even for length==0.
    let len_field_size = std::mem::size_of::<i64>();
    let total = JULIA_HEADER_SIZE + len_field_size + data_size;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if ptr.is_null() { return std::ptr::null_mut(); }

    // Set Julia type pointer at start
    let h = ptr as *mut JuliaGCHeader;
    (*h).type_ptr = type_ptr;

    // Length field (i64, 8 bytes) after type tag — matches fieldoffset(:length)==0
    let len_ptr = ptr.add(JULIA_HEADER_SIZE) as *mut i64;
    *len_ptr = length as i64;

    // Return pointer to element data (past type tag + length field)
    ptr.add(JULIA_HEADER_SIZE + len_field_size)
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
//   [type_tag (8)] [mem_ptr (+0)] [idx (+8)] [length (+16)] [capacity (+24)]
//
// offset +0..+15: MemoryRef {mem, idx} (inlined in Vector's :ref field)
// offset +16:     :size as inline Int64 (Tuple{Int64} stored bare)
// offset +24:     our capacity tracking (beyond Julia-visible sizeof=24)
//
// mem_ptr points to the element data area of a Memory{T} object allocated by
// __jl_gc_alloc_array_julia (emitted via emit_memorynew).  The Memory header
// is at mem_ptr - 4 (i32 length) and mem_ptr - 12 (type tag).

/// Julia-compatible 1-d array representation.  pointer_from_objref returns
/// &elem_ptr — offset 0 of this struct.
///
/// Julia field order (verified via fieldoffset probes):
///   MemoryRef{Int64}:  fieldoffset(:ptr_or_offset) = 0, fieldoffset(:mem) = 8
///   Memory{Int64}:     fieldoffset(:length) = 0 (i64), fieldoffset(:ptr) = 8
///   Vector{Int64}:     sizeof=24, :ref at 0, :size at 16
///
/// Memory layout (from __jl_gc_alloc_array_julia):
///   [type_tag(8)] [length(i64,8)] [element data...]
///   pointer_from_objref  → type_tag + 8   (points to length field)
///   alloc_array_julia ret → type_tag + 16  (points to element data)
#[repr(C)]
pub struct JuliaArrayRepr {
    // offset +0..+7:  MemoryRef.ptr_or_offset (= element data pointer)
    // offset +8..+15: MemoryRef.mem (= pointer_from_objref(Memory))
    pub elem_ptr: *mut u8,  // offset +0: direct element data pointer
    pub mem_obj: *mut u8,   // offset +8: Memory object ref (= pointer_from_objref)
    pub length: i64,        // offset +16: :size as inline Int64
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
/// jl_value_t* (e.g. pointer_from_objref(Vector{Int64})).  `mem_ptr` is the
/// element-data pointer returned by __jl_gc_alloc_array_julia (from the
/// already-emitted emit_memorynew call).  `nel` is the initial element count.
/// The caller (emit_new) already allocated the Memory{T} object; we build the
/// Vector wrapper around it — we do NOT allocate a separate element buffer.
#[no_mangle]
pub unsafe extern "C" fn __jl_array_new_1d(
    atype: *mut u8, mem_ptr: *mut u8, nel: i64,
) -> *mut u8 {
    if atype.is_null() {
        return std::ptr::null_mut();
    }
    let nel = nel.max(0);

    let struct_total = JULIA_HEADER_SIZE + ARRAY_REPR_SIZE;
    let struct_layout = Layout::from_size_align(struct_total, 16).unwrap();
    let alloc = GlobalAlloc::alloc(&GC_ALLOC, struct_layout);
    if alloc.is_null() {
        return std::ptr::null_mut();
    }

    *(alloc as *mut *mut u8) = atype;

    let arr = alloc.add(JULIA_HEADER_SIZE) as *mut JuliaArrayRepr;
    // Memory: [type_tag(8)] [length(i64,8)] [element data...]
    // elem_data_ptr (= mem_ptr arg) = alloc+16 (past type_tag+length)
    // mem_obj (= pointer_from_objref) = alloc+8
    (*arr).elem_ptr = mem_ptr;
    (*arr).mem_obj = mem_ptr.sub(8);
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

    let old_data = (*arr).elem_ptr;
    // Allocate fresh buffer and copy — always works regardless of who
    // originally allocated the old buffer (us or Julia's GC).
    let layout = Layout::from_size_align(new_bytes.max(1), 16).unwrap();
    let new_data = GlobalAlloc::alloc(&GC_ALLOC, layout);
    if !new_data.is_null() {
        if old_bytes > 0 && !old_data.is_null() {
            std::ptr::copy_nonoverlapping(old_data, new_data, old_bytes);
        }
        (*arr).elem_ptr = new_data;
        (*arr).mem_obj = new_data.sub(8);  // mem_obj = elem_ptr - 8
        (*arr).capacity = new_len as i64;
    }
    // If alloc failed, keep old data and length unchanged (arr stays valid)
    if !(*arr).elem_ptr.is_null() {
        (*arr).length = new_len;
        // Sync Memory object's internal length (i64 at mem_obj + 0).
        // mem_obj = pointer_from_objref(Memory), length at fieldoffset 0.
        *((*arr).mem_obj as *mut i64) = new_len as i64;
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
        let data = (*arr).elem_ptr;
        if !data.is_null() {
            std::ptr::write_bytes(data.add(zero_start), 0, zero_bytes);
        }
    }
    (*arr).length = new_len;
    // Sync Memory object's internal length (i64 at mem_obj+0)
    if !(*arr).mem_obj.is_null() {
        *((*arr).mem_obj as *mut i64) = new_len as i64;
    }
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
