// GC allocator — one-shot bump arena for Julia-compatible objects.
//
// All `__jl_gc_*` allocations land in a thread-local bump arena that never
// frees individual objects.  A single `__jl_gc_reset()` call frees every block
// at once, reclaiming all memory allocated since the last reset.  The rest of
// the Rust backend (Cranelift, std containers) uses the normal system allocator
// — only the `__jl_gc_*` / `__jl_array_new_1d` / `__jl_array_grow_end` /
// `rust_alloc_string` family goes through the arena.
//
// This keeps the design simple: no GC, no ref-counting, no per-object free
// bookkeeping — just a leaky arena that can be torn down between test suites.

use std::alloc::Layout;
use std::cell::RefCell;

// ----------------------------------------------------------------
// Bump arena (thread-local, never frees individual allocs)
// ----------------------------------------------------------------

const DEFAULT_BLOCK_SIZE: usize = 65536; // 64 KB

struct Arena {
    blocks: Vec<(*mut u8, usize)>, // (block_base, block_capacity)
    current: *mut u8,
    remaining: usize,
    allocated: usize,              // total bytes bump'd since last reset
}

impl Arena {
    fn new() -> Self {
        Arena { blocks: Vec::new(), current: std::ptr::null_mut(), remaining: 0, allocated: 0 }
    }

    /// Allocate `size` bytes aligned to `align` inside the arena.  Falls back
    /// to a fresh system-allocated block when the current block is exhausted.
    fn bump(&mut self, size: usize, align: usize) -> *mut u8 {
        let offset = (self.current as usize) & (align - 1);
        let padding = if offset == 0 { 0 } else { align - offset };
        let needed = size.checked_add(padding).unwrap_or(usize::MAX);

        if needed <= self.remaining {
            let ptr = unsafe { self.current.add(padding) };
            self.current = unsafe { ptr.add(size) };
            self.remaining -= needed;
            self.allocated += size;
            ptr
        } else {
            // Current block exhausted — allocate a fresh one.
            let block_size = core::cmp::max(DEFAULT_BLOCK_SIZE, size);
            let layout = Layout::from_size_align(block_size, align).unwrap();
            let block = unsafe { std::alloc::alloc(layout) };
            if block.is_null() { unreachable!("oom"); }
            self.blocks.push((block, block_size));
            self.current = block;
            self.remaining = block_size;
            // Retry once with the fresh block (guaranteed to fit for size≤block_size).
            self.bump(size, align)
        }
    }

    fn reset(&mut self) {
        for &(block, cap) in &self.blocks {
            let layout = Layout::from_size_align(cap, 16).unwrap();
            unsafe { std::alloc::dealloc(block, layout); }
        }
        self.blocks.clear();
        self.current = std::ptr::null_mut();
        self.remaining = 0;
        self.allocated = 0;
    }
}

thread_local! {
    static ARENA: RefCell<Arena> = RefCell::new(Arena::new());
}

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_reset() {
    ARENA.with(|a| a.borrow_mut().reset());
    // Cached const objects (Symbols via SYM_INTERN, rodata-memoized literals/
    // tables via RODATA_CACHE) are arena-allocated, so they dangle after the
    // reset. Clear both caches: this bounds memoized state to one parse and
    // fixes a latent use-after-free for multi-input-per-process callers.
    SYM_INTERN.with(|t| t.borrow_mut().clear());
    RODATA_CACHE.with(|c| c.borrow_mut().clear());
}
/// Return total bytes allocated through the bump arena since the last reset.
#[no_mangle]
pub unsafe extern "C" fn __jl_gc_usage() -> i64 {
    ARENA.with(|a| a.borrow().allocated as i64)
}

/// Raw bump-alloc: returns `size` bytes with `align`-byte alignment.
fn bump_alloc(size: usize, align: usize) -> *mut u8 {
    ARENA.with(|a| a.borrow_mut().bump(size, align))
}

// Per-parse cache of const objects keyed by their .rodata address, so each const
// is built ONCE per parse (not per use — the emitter can't CSE across blocks due
// to Cranelift SSA dominance). Objects are arena-allocated; __jl_gc_reset clears
// this so stale pointers never survive a reset. Keyed by the rodata `data`
// pointer each builder receives (stable within the .so image).
thread_local! {
    static RODATA_CACHE: std::cell::RefCell<std::collections::HashMap<usize, *mut u8>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
}

#[inline]
pub(crate) fn get_or_build_rodata(key: usize, builder: impl FnOnce() -> *mut u8) -> *mut u8 {
    RODATA_CACHE.with(|c| {
        if let Some(&p) = c.borrow().get(&key) {
            return p;
        }
        let p = builder();
        c.borrow_mut().insert(key, p);
        p
    })
}

/// Build a read-only Julia-compatible array wrapper whose element data lives in
/// the .so's .rodata (a const table baked via builder_declare_data). `data` points
/// at the rodata element bytes; we allocate only the small Vector wrapper
/// (JuliaGCHeader + JuliaArrayRepr) in the arena and point elem_ptr at the rodata.
/// Read-only: length/getindex work; mutation (grow/push!) is unsupported on rodata.
#[no_mangle]
pub unsafe extern "C" fn __jl_array_alias_rodata(
    data: *mut u8, len: i64, _elem_size: i64, type_id: u32,
) -> *mut u8 {
    if data.is_null() {
        return std::ptr::null_mut();
    }
    let key = data as usize;
    get_or_build_rodata(key, || {
        let n = len.max(0) as i64;
        let type_ptr = __jl_type_tag(type_id);
        let struct_total = JULIA_HEADER_SIZE + ARRAY_REPR_SIZE;
        let alloc = bump_alloc(struct_total, 16);
        if alloc.is_null() {
            unreachable!("oom");
        }
        *(alloc as *mut *mut u8) = type_ptr; // Vector's header type tag
        let arr = alloc.add(JULIA_HEADER_SIZE) as *mut JuliaArrayRepr;
        (*arr).elem_ptr = data;                          // → rodata (read-only)
        (*arr).mem_obj = alloc.add(JULIA_HEADER_SIZE);   // self (no separate Memory)
        (*arr).length = n;
        (*arr).capacity = n;
        alloc.add(JULIA_HEADER_SIZE)
    })
}
/// and return its address. Used for >8-byte bitstype constants (e.g. RawGreenNode)
/// and other flat-data constants so their bytes live in the .so — no baked
/// Julia-heap pointer. Bitstypes have value semantics, so a fresh copy per use
/// is correct (=== compares by content).
#[no_mangle]
pub unsafe extern "C" fn __jl_bytes_dup(src: *const u8, len: i64) -> *mut u8 {
    if src.is_null() || len <= 0 {
        return std::ptr::null_mut();
    }
    let key = src as usize;
    get_or_build_rodata(key, || {
        let n = len as usize;
        let dst = bump_alloc(n, 16);
        if dst.is_null() {
            unreachable!("oom");
        }
        std::ptr::copy_nonoverlapping(src, dst, n);
        dst
    })
}

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

// === Standalone type-tag registry ===
//
// Every Julia type the compiler references is identified by a stable integer
// TypeID (assigned in builder_emit.jl::_type_id). __jl_type_tag(id) returns a
// unique address used as the object-header type tag AND as the isa/typeof
// comparison constant. Type tags are ONLY equality-compared — never
// dereferenced as a real jl_datatype_t — so any stable unique address works.
//
// Default (standalone host, no Julia): each ID maps to a distinct BSS address
// (the slot's own address), so allocator-stores and isa/typeof-compares agree
// without any Julia runtime present.
//
// In-process override: the Julia dispatcher calls __jl_register_type with
// pointer_from_objref(T) for each type, so the tag IS the real jl_datatype_t*
// and Julia's unsafe_pointer_to_objref (which reads the header tag) and _gcall's
// nothing comparison keep working unchanged. Reserved IDs: 0=Nothing,1=String,
// 2=Symbol,3=Any.
pub const TYPE_TABLE_SIZE: usize = 4096;
static mut TYPE_TABLE: [*mut u8; TYPE_TABLE_SIZE] = [core::ptr::null_mut(); TYPE_TABLE_SIZE];

// Reserved TypeIDs — MUST match builder_emit.jl (_STRING_TYPE_ID etc.).
pub const NOTHING_TYPE_ID: u32 = 0;
pub const STRING_TYPE_ID: u32 = 1;
pub const SYMBOL_TYPE_ID: u32 = 2;
pub const ANY_TYPE_ID: u32 = 3;

#[inline]
unsafe fn type_slot(idx: usize) -> *mut *mut u8 {
    // Raw-pointer access avoids creating a &mut to a `static mut` (the
    // static_mut_refs lint). Each slot holds the runtime-resolved type tag.
    (core::ptr::addr_of_mut!(TYPE_TABLE) as *mut *mut u8).add(idx)
}

#[no_mangle]
pub unsafe extern "C" fn __jl_type_tag(id: u32) -> *mut u8 {
    let idx = (id as usize).min(TYPE_TABLE_SIZE - 1);
    let slot = type_slot(idx);
    let p = *slot;
    if p.is_null() {
        // Lazy default: a distinct stable address (the slot's own address).
        *slot = slot as *mut u8;
        return *slot;
    }
    p
}

#[no_mangle]
pub unsafe extern "C" fn __jl_nothing_tag() -> *mut u8 {
    __jl_type_tag(0)
}

/// Host override: record the real Julia datatype pointer for a TypeID. Called by
/// the Julia dispatcher after dlopen so in-process object returns stay correct.
/// Standalone hosts never call this; tags remain distinct BSS addresses.
#[no_mangle]
pub unsafe extern "C" fn __jl_register_type(id: u32, type_ptr: *mut u8) {
    let idx = (id as usize).min(TYPE_TABLE_SIZE - 1);
    *type_slot(idx) = type_ptr;
}

// Symbol interning table (name bytes → stable Symbol address). Symbols compare by
// identity (===), so every use of the same name must return the SAME address —
// hence a per-process intern table, not a per-use allocation.
thread_local! {
    static SYM_INTERN: std::cell::RefCell<Vec<(Vec<u8>, *mut u8)>> =
        std::cell::RefCell::new(Vec::new());
}

/// Build/look up a standalone Symbol from its name bytes (.rodata). Layout matches
/// Julia's jl_sym_t data (past the type tag): hash@0 (placeholder 0 — Symbol hash
/// reads are rare in the parser hot path), inline null-terminated name@8. Interned
/// by name so `:foo === :foo` holds across uses.
#[no_mangle]
pub unsafe extern "C" fn __jl_intern_symbol(name: *const u8, len: i32) -> *mut u8 {
    let n = (len.max(0)) as usize;
    let nb: Vec<u8> = if n == 0 || name.is_null() {
        Vec::new()
    } else {
        std::slice::from_raw_parts(name, n).to_vec()
    };
    let existing = SYM_INTERN.with(|t| {
        t.borrow().iter().find(|(v, _)| *v == nb).map(|(_, p)| *p)
    });
    if let Some(p) = existing {
        return p;
    }
    let type_ptr = __jl_type_tag(SYMBOL_TYPE_ID);
    let total = 8 /*type tag*/ + 8 /*hash*/ + n + 1 /*nul*/;
    let alloc = bump_alloc(total, 16);
    if alloc.is_null() { unreachable!("oom"); }
    *(alloc as *mut *mut u8) = type_ptr;        // header type tag
    *(alloc.add(8) as *mut i64) = 0;            // hash placeholder
    let name_dst = alloc.add(16);
    if n > 0 && !name.is_null() {
        std::ptr::copy_nonoverlapping(name, name_dst, n);
    }
    *name_dst.add(n) = 0;                        // null terminator
    let sym = alloc.add(8); // past type tag → &hash@0, name@8
    SYM_INTERN.with(|t| t.borrow_mut().push((nb, sym)));
    sym
}

/// Build a standalone, Julia-layout-compatible Dict from three .rodata byte
/// blobs (slots/keys/vals) carried in the .so. The const Dict{K,V} is serialized
/// verbatim: the getindex traverses the existing hash table (slot occupancy +
/// key placement baked into slots/keys/vals), so a faithful byte copy parses
/// identically. Dict layout (verified via fieldoffset probes): a 64-byte mutable
/// struct whose slots/keys/vals fields are POINTERS to 16-byte Memory objects
/// {length@0, data_ptr@8}, plus ndel/count/age/idxfloor/maxprobe scalars.
/// Bits-element Dicts only (K,V bits); String-keyed/valued Dicts need per-element
/// String serialization (not handled here).
#[no_mangle]
pub unsafe extern "C" fn __jl_dict_from_rodata(
    slots_data: *const u8, keys_data: *const u8, vals_data: *const u8,
    nslots: i64, keys_is_str: i32, vals_is_str: i32,
    ndel: i64, count: i64, idxfloor: i64, maxprobe: i64,
    type_id: u32,
) -> *mut u8 {
    get_or_build_rodata(slots_data as usize, || {
    let type_ptr = __jl_type_tag(type_id);
    // Bits-element Memory: [length@0 = nslots, data_ptr@8 → rodata (read-only)].
    let mk_mem = |data: *const u8| -> *mut u8 {
        let m = bump_alloc(16, 16);
        if m.is_null() { unreachable!("oom"); }
        *(m as *mut i64) = nslots;
        *(m.add(8) as *mut *const u8) = data;
        m
    };
    // String-element Memory: build each element via __jl_string_from_raw from a
    // .rodata sequence of (len:i32, bytes[len]) per slot, write the resulting
    // String ptrs into an arena array. Empty slots serialize len=0 → empty String
    // (never read by the getindex, which only reads filled slots).
    let build_str_mem = |seq: *const u8| -> *mut u8 {
        let arr = bump_alloc((nslots as usize) * 8, 16);
        if arr.is_null() { unreachable!("oom"); }
        let mut p = seq;
        for i in 0..(nslots as usize) {
            let len = if p.is_null() { 0i32 } else { *(p as *const i32) };
            let len = len.max(0);
            let bytes = if len == 0 { std::ptr::null() } else { p.add(4) };
            let s = crate::runtime::strings::__jl_string_from_raw(bytes, len);
            *((arr.add(i * 8)) as *mut *mut u8) = s;
            if !p.is_null() { p = p.add(4 + len as usize); }
        }
        let m = bump_alloc(16, 16);
        if m.is_null() { unreachable!("oom"); }
        *(m as *mut i64) = nslots;
        *(m.add(8) as *mut *mut u8) = arr;
        m
    };
    let slots_mem = mk_mem(slots_data);
    let keys_mem = if keys_is_str != 0 { build_str_mem(keys_data) } else { mk_mem(keys_data) };
    let vals_mem = if vals_is_str != 0 { build_str_mem(vals_data) } else { mk_mem(vals_data) };
    if std::env::var("NCG_TRACE_DICT").is_ok() {
        eprintln!("[dict] nslots={} count={} keys_is_str={} vals_is_str={} slots[0..4]={:?}",
            nslots, count, keys_is_str, vals_is_str,
            if slots_data.is_null() { Vec::new() } else {
                (0..(nslots as usize).min(4)).map(|i| *slots_data.add(i)).collect::<Vec<u8>>()
            });
    }
    // Dict struct: header(type tag) + 64 bytes.
    let dict = __jl_gc_alloc_julia(type_ptr, 64);
    if dict.is_null() { unreachable!("oom"); }
    *(dict.add(0) as *mut *mut u8) = slots_mem;   // :slots → Memory{UInt8}
    *(dict.add(8) as *mut *mut u8) = keys_mem;    // :keys  → Memory{K}
    *(dict.add(16) as *mut *mut u8) = vals_mem;   // :vals  → Memory{V}
    *(dict.add(24) as *mut i64) = ndel;
    *(dict.add(32) as *mut i64) = count;
    *(dict.add(40) as *mut i64) = 0;              // :age
    *(dict.add(48) as *mut i64) = idxfloor;
    *(dict.add(56) as *mut i64) = maxprobe;
    dict
    })
}

#[no_mangle]
pub unsafe extern "C" fn __jl_gc_alloc(type_tag: u32, data_size: u32) -> *mut u8 {
    let total = HEADER_SIZE + data_size as usize;
    let ptr = bump_alloc(total, 16);
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
    let ptr = bump_alloc(total, 16);
    if ptr.is_null() { unreachable!("oom"); }
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
    let ptr = bump_alloc(total, 16);
    if ptr.is_null() { unreachable!("oom"); }

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
    let ptr = bump_alloc(total, 16);
    if ptr.is_null() { unreachable!("oom"); }

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
    let alloc = bump_alloc(total, 16);
    if alloc.is_null() { unreachable!("oom"); }
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
    let alloc = bump_alloc(struct_total, 16);
    if alloc.is_null() { unreachable!("oom"); }

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
    // Allocate a FULL Memory object layout [type_ptr(8)][length(i64,8)][data...],
    // exactly matching __jl_gc_alloc_array_julia, so that mem_obj (= data - 8)
    // points at a VALID in-allocation length field. The prior code allocated
    // ONLY the data bytes and then wrote the length at `data - 8` — an 8-byte
    // heap UNDERFLOW that corrupted whatever object preceded the new buffer on
    // every push!. With a push!-heavy parser this silently corrupted the heap
    // and surfaced as the composition-only SIGSEGV in __lookahead_index.
    let len_field_size = std::mem::size_of::<i64>();
    let total = JULIA_HEADER_SIZE + len_field_size + new_bytes;
    let new_alloc = bump_alloc(total, 16);
    {
        // Preserve the Memory's type pointer (GC tracing / type-tag queries).
        // It lives JULIA_HEADER_SIZE + len_field_size (= 16) bytes before the
        // data pointer in both the original and prior-grow layouts.
        if !old_data.is_null() {
            let old_type_ptr = *(old_data.sub(JULIA_HEADER_SIZE + len_field_size) as *mut *mut u8);
            *(new_alloc as *mut *mut u8) = old_type_ptr;
        }
        let new_data = new_alloc.add(JULIA_HEADER_SIZE + len_field_size);
        if old_bytes > 0 && !old_data.is_null() {
            std::ptr::copy_nonoverlapping(old_data, new_data, old_bytes);
        }
        // Length field (i64) at alloc + JULIA_HEADER_SIZE (= new_data - 8): the
        // location pointer_from_objref(Memory) points at; a valid in-allocation
        // write (not an underflow).
        *(new_alloc.add(JULIA_HEADER_SIZE) as *mut i64) = new_len;
        (*arr).elem_ptr = new_data;
        (*arr).mem_obj = new_alloc.add(JULIA_HEADER_SIZE);  // = new_data - 8 (valid)
        (*arr).capacity = new_len as i64;
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
