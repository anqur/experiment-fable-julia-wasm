// GC type descriptors for the runtime. Maps Julia GC types to layout info.

/// Describes a GC-managed struct field.
#[repr(C)]
pub struct FieldDesc {
    pub offset: u32,     // byte offset from object start
    pub kind: FieldKind, // type of the field
}

#[repr(u32)]
pub enum FieldKind {
    I8  = 0,
    I16 = 1,
    I32 = 2,
    I64 = 3,
    F32 = 4,
    F64 = 5,
    Ref = 6,  // nullable GC reference
}

/// Describes a GC-managed type (struct or array).
#[repr(C)]
pub struct GCTypeInfo {
    pub type_tag: u32,
    pub total_size: u32,        // total byte size including header
    pub num_fields: u32,
    pub fields: *const FieldDesc, // pointer to field array
    pub is_array: u8,
    pub elem_size: u32,         // for array types
}
