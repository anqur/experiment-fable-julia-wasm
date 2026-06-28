// GC allocator — malloc-based with type tags.

use std::alloc::{Layout, alloc};

#[repr(C)]
pub struct GCHeader {
    pub type_tag: u32,
    pub flags: u32,
    pub length: i32,
}

const HEADER_SIZE: usize = std::mem::size_of::<GCHeader>();

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc(type_tag: u32, data_size: u32) -> *mut u8 {
    let total = HEADER_SIZE + data_size as usize;
    let layout = Layout::from_size_align(total, 16).unwrap();
    let ptr = alloc(layout);
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
    let ptr = alloc(layout);
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
