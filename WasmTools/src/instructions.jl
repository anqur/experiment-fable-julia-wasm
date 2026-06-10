# Instruction representation and the opcode table.
#
# Instructions are stored flat (as in the binary format): structured control
# (`block`/`loop`/`if` ... `end`) appears as explicit instructions. Function
# bodies and init expressions do NOT store the terminating `end`; the encoder
# appends it.

"""Memory-access immediate. `memidx != 0` uses the multi-memory encoding."""
struct MemArg
    align::UInt32
    offset::UInt64
    memidx::UInt32
end
MemArg(; align::Integer=0, offset::Integer=0, memidx::Integer=0) =
    MemArg(UInt32(align), UInt64(offset), UInt32(memidx))

"""
Block type immediate: `nothing` (no result), a single `ValType` result, or an
`Integer` index of a function type in the type section.
"""
const BlockTypeImm = Union{Nothing, ValType, Int64}

"""One catch clause of a `try_table`. `kind`: 0=catch 1=catch_ref 2=catch_all 3=catch_all_ref."""
struct Catch
    kind::UInt8
    tag::UInt32    # unused for catch_all/catch_all_ref
    label::UInt32
end

"""
A single wasm instruction: opcode symbol (wat mnemonic with `.` replaced by
`_`, e.g. `:i32_add`, `:local_get`, `:array_new_fixed`) plus immediates.
"""
struct Inst
    op::Symbol
    imm::Tuple
end
Inst(op::Symbol, args...) = Inst(op, args)

Base.:(==)(a::Inst, b::Inst) = a.op == b.op && isequal(a.imm, b.imm)
Base.hash(a::Inst, h::UInt) = hash(a.imm, hash(a.op, h))

function Base.show(io::IO, inst::Inst)
    print(io, "Inst(", repr(inst.op))
    for x in inst.imm
        print(io, ", ", x isa Vector{UInt8} ? repr(x) : repr(x))
    end
    print(io, ")")
end

struct OpSpec
    op::Symbol
    wat::String
    prefix::UInt8
    sub::Int32              # -1 for single-byte opcodes, else the LEB sub-opcode
    imm::Vector{Symbol}     # immediate schema
end

# Immediate schema kinds:
#   :u32        unsigned LEB index / count
#   :u32vec     vector of u32 (e.g. br_table targets)
#   :i32 :i64   signed LEB constant payload
#   :f32 :f64   raw little-endian IEEE754
#   :memarg     MemArg
#   :blocktype  BlockTypeImm
#   :heaptype   HeapType
#   :valtypevec vector of ValType (typed select)
#   :u8         raw byte (cast flags)
#   :catchvec   vector of Catch (try_table)

const _INSTRUCTIONS = [
    # --- control ---------------------------------------------------------
    ("unreachable",          (0x00,), ()),
    ("nop",                  (0x01,), ()),
    ("block",                (0x02,), (:blocktype,)),
    ("loop",                 (0x03,), (:blocktype,)),
    ("if",                   (0x04,), (:blocktype,)),
    ("else",                 (0x05,), ()),
    ("throw",                (0x08,), (:u32,)),
    ("throw_ref",            (0x0A,), ()),
    ("end",                  (0x0B,), ()),
    ("br",                   (0x0C,), (:u32,)),
    ("br_if",                (0x0D,), (:u32,)),
    ("br_table",             (0x0E,), (:u32vec, :u32)),
    ("return",               (0x0F,), ()),
    ("call",                 (0x10,), (:u32,)),
    ("call_indirect",        (0x11,), (:u32, :u32)),    # typeidx, tableidx
    ("return_call",          (0x12,), (:u32,)),
    ("return_call_indirect", (0x13,), (:u32, :u32)),
    ("call_ref",             (0x14,), (:u32,)),
    ("return_call_ref",      (0x15,), (:u32,)),
    ("try_table",            (0x1F,), (:blocktype, :catchvec)),
    # --- parametric ------------------------------------------------------
    ("drop",                 (0x1A,), ()),
    ("select",               (0x1B,), ()),
    (("select_t", "select"), (0x1C,), (:valtypevec,)),
    # --- variable --------------------------------------------------------
    ("local.get",            (0x20,), (:u32,)),
    ("local.set",            (0x21,), (:u32,)),
    ("local.tee",            (0x22,), (:u32,)),
    ("global.get",           (0x23,), (:u32,)),
    ("global.set",           (0x24,), (:u32,)),
    # --- table -----------------------------------------------------------
    ("table.get",            (0x25,), (:u32,)),
    ("table.set",            (0x26,), (:u32,)),
    # --- memory ----------------------------------------------------------
    ("i32.load",             (0x28,), (:memarg,)),
    ("i64.load",             (0x29,), (:memarg,)),
    ("f32.load",             (0x2A,), (:memarg,)),
    ("f64.load",             (0x2B,), (:memarg,)),
    ("i32.load8_s",          (0x2C,), (:memarg,)),
    ("i32.load8_u",          (0x2D,), (:memarg,)),
    ("i32.load16_s",         (0x2E,), (:memarg,)),
    ("i32.load16_u",         (0x2F,), (:memarg,)),
    ("i64.load8_s",          (0x30,), (:memarg,)),
    ("i64.load8_u",          (0x31,), (:memarg,)),
    ("i64.load16_s",         (0x32,), (:memarg,)),
    ("i64.load16_u",         (0x33,), (:memarg,)),
    ("i64.load32_s",         (0x34,), (:memarg,)),
    ("i64.load32_u",         (0x35,), (:memarg,)),
    ("i32.store",            (0x36,), (:memarg,)),
    ("i64.store",            (0x37,), (:memarg,)),
    ("f32.store",            (0x38,), (:memarg,)),
    ("f64.store",            (0x39,), (:memarg,)),
    ("i32.store8",           (0x3A,), (:memarg,)),
    ("i32.store16",          (0x3B,), (:memarg,)),
    ("i64.store8",           (0x3C,), (:memarg,)),
    ("i64.store16",          (0x3D,), (:memarg,)),
    ("i64.store32",          (0x3E,), (:memarg,)),
    ("memory.size",          (0x3F,), (:u32,)),
    ("memory.grow",          (0x40,), (:u32,)),
    # --- constants -------------------------------------------------------
    ("i32.const",            (0x41,), (:i32,)),
    ("i64.const",            (0x42,), (:i64,)),
    ("f32.const",            (0x43,), (:f32,)),
    ("f64.const",            (0x44,), (:f64,)),
    # --- i32 compare/arith ----------------------------------------------
    ("i32.eqz",  (0x45,), ()), ("i32.eq",   (0x46,), ()), ("i32.ne",   (0x47,), ()),
    ("i32.lt_s", (0x48,), ()), ("i32.lt_u", (0x49,), ()), ("i32.gt_s", (0x4A,), ()),
    ("i32.gt_u", (0x4B,), ()), ("i32.le_s", (0x4C,), ()), ("i32.le_u", (0x4D,), ()),
    ("i32.ge_s", (0x4E,), ()), ("i32.ge_u", (0x4F,), ()),
    ("i64.eqz",  (0x50,), ()), ("i64.eq",   (0x51,), ()), ("i64.ne",   (0x52,), ()),
    ("i64.lt_s", (0x53,), ()), ("i64.lt_u", (0x54,), ()), ("i64.gt_s", (0x55,), ()),
    ("i64.gt_u", (0x56,), ()), ("i64.le_s", (0x57,), ()), ("i64.le_u", (0x58,), ()),
    ("i64.ge_s", (0x59,), ()), ("i64.ge_u", (0x5A,), ()),
    ("f32.eq", (0x5B,), ()), ("f32.ne", (0x5C,), ()), ("f32.lt", (0x5D,), ()),
    ("f32.gt", (0x5E,), ()), ("f32.le", (0x5F,), ()), ("f32.ge", (0x60,), ()),
    ("f64.eq", (0x61,), ()), ("f64.ne", (0x62,), ()), ("f64.lt", (0x63,), ()),
    ("f64.gt", (0x64,), ()), ("f64.le", (0x65,), ()), ("f64.ge", (0x66,), ()),
    ("i32.clz",    (0x67,), ()), ("i32.ctz",    (0x68,), ()), ("i32.popcnt", (0x69,), ()),
    ("i32.add",    (0x6A,), ()), ("i32.sub",    (0x6B,), ()), ("i32.mul",    (0x6C,), ()),
    ("i32.div_s",  (0x6D,), ()), ("i32.div_u",  (0x6E,), ()), ("i32.rem_s",  (0x6F,), ()),
    ("i32.rem_u",  (0x70,), ()), ("i32.and",    (0x71,), ()), ("i32.or",     (0x72,), ()),
    ("i32.xor",    (0x73,), ()), ("i32.shl",    (0x74,), ()), ("i32.shr_s",  (0x75,), ()),
    ("i32.shr_u",  (0x76,), ()), ("i32.rotl",   (0x77,), ()), ("i32.rotr",   (0x78,), ()),
    ("i64.clz",    (0x79,), ()), ("i64.ctz",    (0x7A,), ()), ("i64.popcnt", (0x7B,), ()),
    ("i64.add",    (0x7C,), ()), ("i64.sub",    (0x7D,), ()), ("i64.mul",    (0x7E,), ()),
    ("i64.div_s",  (0x7F,), ()), ("i64.div_u",  (0x80,), ()), ("i64.rem_s",  (0x81,), ()),
    ("i64.rem_u",  (0x82,), ()), ("i64.and",    (0x83,), ()), ("i64.or",     (0x84,), ()),
    ("i64.xor",    (0x85,), ()), ("i64.shl",    (0x86,), ()), ("i64.shr_s",  (0x87,), ()),
    ("i64.shr_u",  (0x88,), ()), ("i64.rotl",   (0x89,), ()), ("i64.rotr",   (0x8A,), ()),
    ("f32.abs",     (0x8B,), ()), ("f32.neg",      (0x8C,), ()), ("f32.ceil", (0x8D,), ()),
    ("f32.floor",   (0x8E,), ()), ("f32.trunc",    (0x8F,), ()), ("f32.nearest", (0x90,), ()),
    ("f32.sqrt",    (0x91,), ()), ("f32.add",      (0x92,), ()), ("f32.sub",  (0x93,), ()),
    ("f32.mul",     (0x94,), ()), ("f32.div",      (0x95,), ()), ("f32.min",  (0x96,), ()),
    ("f32.max",     (0x97,), ()), ("f32.copysign", (0x98,), ()),
    ("f64.abs",     (0x99,), ()), ("f64.neg",      (0x9A,), ()), ("f64.ceil", (0x9B,), ()),
    ("f64.floor",   (0x9C,), ()), ("f64.trunc",    (0x9D,), ()), ("f64.nearest", (0x9E,), ()),
    ("f64.sqrt",    (0x9F,), ()), ("f64.add",      (0xA0,), ()), ("f64.sub",  (0xA1,), ()),
    ("f64.mul",     (0xA2,), ()), ("f64.div",      (0xA3,), ()), ("f64.min",  (0xA4,), ()),
    ("f64.max",     (0xA5,), ()), ("f64.copysign", (0xA6,), ()),
    # --- conversions -----------------------------------------------------
    ("i32.wrap_i64",        (0xA7,), ()),
    ("i32.trunc_f32_s",     (0xA8,), ()), ("i32.trunc_f32_u",     (0xA9,), ()),
    ("i32.trunc_f64_s",     (0xAA,), ()), ("i32.trunc_f64_u",     (0xAB,), ()),
    ("i64.extend_i32_s",    (0xAC,), ()), ("i64.extend_i32_u",    (0xAD,), ()),
    ("i64.trunc_f32_s",     (0xAE,), ()), ("i64.trunc_f32_u",     (0xAF,), ()),
    ("i64.trunc_f64_s",     (0xB0,), ()), ("i64.trunc_f64_u",     (0xB1,), ()),
    ("f32.convert_i32_s",   (0xB2,), ()), ("f32.convert_i32_u",   (0xB3,), ()),
    ("f32.convert_i64_s",   (0xB4,), ()), ("f32.convert_i64_u",   (0xB5,), ()),
    ("f32.demote_f64",      (0xB6,), ()),
    ("f64.convert_i32_s",   (0xB7,), ()), ("f64.convert_i32_u",   (0xB8,), ()),
    ("f64.convert_i64_s",   (0xB9,), ()), ("f64.convert_i64_u",   (0xBA,), ()),
    ("f64.promote_f32",     (0xBB,), ()),
    ("i32.reinterpret_f32", (0xBC,), ()), ("i64.reinterpret_f64", (0xBD,), ()),
    ("f32.reinterpret_i32", (0xBE,), ()), ("f64.reinterpret_i64", (0xBF,), ()),
    ("i32.extend8_s",       (0xC0,), ()), ("i32.extend16_s",      (0xC1,), ()),
    ("i64.extend8_s",       (0xC2,), ()), ("i64.extend16_s",      (0xC3,), ()),
    ("i64.extend32_s",      (0xC4,), ()),
    # --- reference instructions -----------------------------------------
    ("ref.null",        (0xD0,), (:heaptype,)),
    ("ref.is_null",     (0xD1,), ()),
    ("ref.func",        (0xD2,), (:u32,)),
    ("ref.eq",          (0xD3,), ()),
    ("ref.as_non_null", (0xD4,), ()),
    ("br_on_null",      (0xD5,), (:u32,)),
    ("br_on_non_null",  (0xD6,), (:u32,)),
    # --- 0xFB: GC --------------------------------------------------------
    ("struct.new",          (0xFB, 0),  (:u32,)),
    ("struct.new_default",  (0xFB, 1),  (:u32,)),
    ("struct.get",          (0xFB, 2),  (:u32, :u32)),   # typeidx, fieldidx
    ("struct.get_s",        (0xFB, 3),  (:u32, :u32)),
    ("struct.get_u",        (0xFB, 4),  (:u32, :u32)),
    ("struct.set",          (0xFB, 5),  (:u32, :u32)),
    ("array.new",           (0xFB, 6),  (:u32,)),
    ("array.new_default",   (0xFB, 7),  (:u32,)),
    ("array.new_fixed",     (0xFB, 8),  (:u32, :u32)),   # typeidx, length
    ("array.new_data",      (0xFB, 9),  (:u32, :u32)),   # typeidx, dataidx
    ("array.new_elem",      (0xFB, 10), (:u32, :u32)),   # typeidx, elemidx
    ("array.get",           (0xFB, 11), (:u32,)),
    ("array.get_s",         (0xFB, 12), (:u32,)),
    ("array.get_u",         (0xFB, 13), (:u32,)),
    ("array.set",           (0xFB, 14), (:u32,)),
    ("array.len",           (0xFB, 15), ()),
    ("array.fill",          (0xFB, 16), (:u32,)),
    ("array.copy",          (0xFB, 17), (:u32, :u32)),   # dst typeidx, src typeidx
    ("array.init_data",     (0xFB, 18), (:u32, :u32)),
    ("array.init_elem",     (0xFB, 19), (:u32, :u32)),
    (("ref_test", "ref.test"),           (0xFB, 20), (:heaptype,)),
    (("ref_test_null", "ref.test"),      (0xFB, 21), (:heaptype,)),
    (("ref_cast", "ref.cast"),           (0xFB, 22), (:heaptype,)),
    (("ref_cast_null", "ref.cast"),      (0xFB, 23), (:heaptype,)),
    ("br_on_cast",          (0xFB, 24), (:u8, :u32, :heaptype, :heaptype)),  # flags, label, from, to
    ("br_on_cast_fail",     (0xFB, 25), (:u8, :u32, :heaptype, :heaptype)),
    ("any.convert_extern",  (0xFB, 26), ()),
    ("extern.convert_any",  (0xFB, 27), ()),
    ("ref.i31",             (0xFB, 28), ()),
    ("i31.get_s",           (0xFB, 29), ()),
    ("i31.get_u",           (0xFB, 30), ()),
    # --- 0xFC: saturating truncation + bulk memory/table ----------------
    ("i32.trunc_sat_f32_s", (0xFC, 0), ()), ("i32.trunc_sat_f32_u", (0xFC, 1), ()),
    ("i32.trunc_sat_f64_s", (0xFC, 2), ()), ("i32.trunc_sat_f64_u", (0xFC, 3), ()),
    ("i64.trunc_sat_f32_s", (0xFC, 4), ()), ("i64.trunc_sat_f32_u", (0xFC, 5), ()),
    ("i64.trunc_sat_f64_s", (0xFC, 6), ()), ("i64.trunc_sat_f64_u", (0xFC, 7), ()),
    ("memory.init", (0xFC, 8),  (:u32, :u32)),   # dataidx, memidx
    ("data.drop",   (0xFC, 9),  (:u32,)),
    ("memory.copy", (0xFC, 10), (:u32, :u32)),   # dst memidx, src memidx
    ("memory.fill", (0xFC, 11), (:u32,)),
    ("table.init",  (0xFC, 12), (:u32, :u32)),   # elemidx, tableidx
    ("elem.drop",   (0xFC, 13), (:u32,)),
    ("table.copy",  (0xFC, 14), (:u32, :u32)),   # dst tableidx, src tableidx
    ("table.grow",  (0xFC, 15), (:u32,)),
    ("table.size",  (0xFC, 16), (:u32,)),
    ("table.fill",  (0xFC, 17), (:u32,)),
]

function _mkspec(entry)
    nameinfo, enc, imm = entry
    if nameinfo isa Tuple
        opname, wat = nameinfo
        op = Symbol(opname)
    else
        wat = nameinfo
        op = Symbol(replace(wat, '.' => '_'))
    end
    prefix = UInt8(enc[1])
    sub = length(enc) == 2 ? Int32(enc[2]) : Int32(-1)
    return OpSpec(op, wat, prefix, sub, collect(Symbol, imm))
end

const OPSPECS = Dict{Symbol,OpSpec}()
const DECODE_SINGLE = Vector{Union{Nothing,OpSpec}}(nothing, 256)
const DECODE_PREFIXED = Dict{Tuple{UInt8,UInt32},OpSpec}()

for entry in _INSTRUCTIONS
    spec = _mkspec(entry)
    haskey(OPSPECS, spec.op) && error("duplicate op $(spec.op)")
    OPSPECS[spec.op] = spec
    if spec.sub == -1
        DECODE_SINGLE[Int(spec.prefix)+1] === nothing ||
            error("duplicate opcode $(spec.prefix)")
        DECODE_SINGLE[Int(spec.prefix)+1] = spec
    else
        haskey(DECODE_PREFIXED, (spec.prefix, UInt32(spec.sub))) &&
            error("duplicate opcode $(spec.prefix) $(spec.sub)")
        DECODE_PREFIXED[(spec.prefix, UInt32(spec.sub))] = spec
    end
end

opspec(op::Symbol) = get(OPSPECS, op) do
    throw(ArgumentError("unknown wasm instruction $op"))
end

"""
    Instructions

Convenience constructors for every instruction, named after the opcode symbol
(`i64_add()`, `local_get(0)`, ...). Names that collide with Julia keywords get
a trailing underscore: `if_`, `else_`, `end_`, `return_`.
"""
module Instructions
import ..WasmTools: Inst, OPSPECS, MemArg, Catch
const _KEYWORDS = ("if", "else", "end", "return", "throw")  # throw: avoid clash with Base.throw
for (op, spec) in OPSPECS
    fname = String(op) in _KEYWORDS ? Symbol(String(op) * "_") : op
    nimm = length(spec.imm)
    if nimm == 0
        @eval $fname() = Inst($(QuoteNode(op)))
    elseif spec.imm == [:blocktype]
        # `block`, `loop`, `if` take an optional blocktype (default: no result).
        @eval $fname(bt=nothing) = Inst($(QuoteNode(op)), (bt,))
    else
        @eval $fname(args...) = begin
            length(args) == $nimm || throw(ArgumentError(string($(QuoteNode(op)), " expects ", $nimm, " immediates, got ", length(args))))
            Inst($(QuoteNode(op)), args)
        end
    end
    @eval export $fname
end
end # module Instructions
