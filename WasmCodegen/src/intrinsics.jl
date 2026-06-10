# Lowering of Julia intrinsics and builtins to wasm instruction sequences.
#
# Each handler receives the function compiler, the (widened) result type, and
# the argument IR references; it must leave exactly the result value on the
# wasm stack (or nothing for ghost results). Handlers evaluate their arguments
# via emit_value!, so evaluation order matches Julia's left-to-right semantics.

# Pick the mnemonic prefix for a numeric wasm type.
function _p(vt::NumType)
    vt == I64 && return "i64"
    vt == I32 && return "i32"
    vt == F64 && return "f64"
    return "f32"
end

_op(vt::NumType, name::String) = Inst(Symbol(_p(vt), "_", name))

"""Constant instruction of the given wasm numeric type."""
function _const(vt::NumType, x)
    vt == I64 && return i64_const(Int64(x))
    vt == I32 && return i32_const(Int32(x))
    vt == F64 && return f64_const(Float64(x))
    return f32_const(Float32(x))
end

"""Renormalize the sub-word value on top of the stack for Julia type `T`."""
function emit_norm!(fc, @nospecialize(T))
    if T === Bool
        # Bool results must stay in {0,1}: e.g. add_int(true,true) is false
        # (1-bit wrap) and trunc_int(Bool, x) takes the low bit. Without the
        # mask, raw i32 values like 2 or 6 escape and flip later branches.
        emit!(fc, i32_const(1), Inst(:i32_and))
        return
    end
    r = scalar_repr(T)
    (r === nothing || r.isfloat || r.bits >= 32 || T === Char) && return
    if r.signed
        emit!(fc, Inst(r.bits == 8 ? :i32_extend8_s : :i32_extend16_s))
    else
        emit!(fc, i32_const(r.bits == 8 ? 0xff : 0xffff), Inst(:i32_and))
    end
end

"""Zero-extend the (possibly sign-extended) sub-word value on top of the stack."""
function emit_zeroext!(fc, @nospecialize(T))
    r = scalar_repr(T)
    (r.bits >= 32 || T === Bool || T === Char) && return
    emit!(fc, i32_const(r.bits == 8 ? 0xff : 0xffff), Inst(:i32_and))
end

"""
Sign-extend the sub-word value on top of the stack at its logical width,
regardless of the repr's signedness. Required by ops that fix a *signed
interpretation* of the bits independent of the Julia type: `ashr_int`,
`slt_int`/`sle_int`, `sext_int`, `sitofp`. (Signed reprs are already kept
sign-extended, so this only changes unsigned sub-word operands; Bool needs no
fix — natively it is an 8-bit 0/1, its own sign extension.)
"""
function emit_signext!(fc, @nospecialize(T))
    r = scalar_repr(T)
    (r === nothing || r.isfloat || r.bits >= 32 || T === Bool || T === Char) && return
    emit!(fc, Inst(r.bits == 8 ? :i32_extend8_s : :i32_extend16_s))
end

function _intty(fc, ref)
    T = argtype(fc, ref)
    r = scalar_repr(T)
    r === nothing && throw(CompileError("expected scalar operand, got $T"))
    return T, r
end

# --- generic shapes ---------------------------------------------------------

"""Binary op named `name` on the operands' common storage type, renormalizing."""
function emit_binop!(fc, name::String, rt, args; norm::Bool=true)
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    emit_value!(fc, args[2])
    emit!(fc, _op(r.vt, name))
    norm && emit_norm!(fc, rt)
end

"""
Comparison producing Bool; uses the operand storage type. `unsigned_fix`
zero-extends sub-word operands for `_u` comparisons on signed reprs;
`signed_fix` sign-extends sub-word operands for `_s` comparisons on unsigned
reprs (e.g. `slt_int` on UInt8 compares the bits as signed).
"""
function emit_cmp!(fc, name::String, args; unsigned_fix::Bool=false,
                   signed_fix::Bool=false)
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    unsigned_fix && !r.signed && emit_zeroext!(fc, T)
    signed_fix && !r.signed && emit_signext!(fc, T)
    emit_value!(fc, args[2])
    unsigned_fix && !r.signed && emit_zeroext!(fc, T)
    signed_fix && !r.signed && emit_signext!(fc, T)
    emit!(fc, _op(r.vt, name))
end

function emit_unop!(fc, name::String, rt, args; norm::Bool=true)
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    emit!(fc, _op(r.vt, name))
    norm && emit_norm!(fc, rt)
end

# --- shifts -----------------------------------------------------------------
# Julia shift intrinsics are total: counts >= bitwidth yield 0 (shl/lshr) or
# sign-fill (ashr). Wasm masks the count, so we add an explicit select.

function _emit_count!(fc, ref, target::NumType)
    _, rc = _intty(fc, ref)
    emit_value!(fc, ref)
    rc.signed || emit_zeroext!(fc, argtype(fc, ref))
    if rc.vt == I32 && target == I64
        emit!(fc, Inst(:i64_extend_i32_u))
    elseif rc.vt == I64 && target == I32
        # Saturate before wrapping: a plain i32.wrap_i64 would alias counts
        # like 2^32 (low 32 bits zero) with 0, defeating the `count < bits`
        # guards below. 64 exceeds every logical width we shift at i32
        # storage, so it is a safe "huge count" sentinel.
        sc = scratch_local!(fc, I64)
        emit!(fc, local_tee(sc), Inst(:i32_wrap_i64), i32_const(64),
              local_get(sc), i64_const(64), Inst(:i64_lt_u), select())
    end
end

function emit_shift!(fc, kind::Symbol, rt, args)
    T, r = _intty(fc, args[1])
    vt = r.vt
    cnt = scratch_local!(fc, vt)
    _emit_count!(fc, args[2], vt)
    emit!(fc, local_set(cnt))
    if kind === :shl
        # c >= bits ? 0 : x << c   (wasm masks the count; result discarded then)
        emit_value!(fc, args[1])
        emit!(fc, local_get(cnt), _op(vt, "shl"))
        emit_norm!(fc, rt)
        emit!(fc, _const(vt, 0))
        emit!(fc, local_get(cnt), _const(vt, r.bits))
        emit!(fc, _op(vt, "lt_u"), select())
    elseif kind === :lshr
        emit_value!(fc, args[1])
        emit_zeroext!(fc, T)
        emit!(fc, local_get(cnt), _op(vt, "shr_u"))
        r.signed && emit_norm!(fc, rt)
        emit!(fc, _const(vt, 0))
        emit!(fc, local_get(cnt), _const(vt, r.bits))
        emit!(fc, _op(vt, "lt_u"), select())
    else # ashr: clamp count to storage width - 1; sign-extended value is exact
        emit_value!(fc, args[1])
        emit_signext!(fc, T)   # signed interpretation even for unsigned reprs
        storage_bits = vt == I64 ? 64 : 32
        emit!(fc, local_get(cnt))
        emit!(fc, _const(vt, storage_bits - 1))
        emit!(fc, local_get(cnt), _const(vt, storage_bits - 1))
        emit!(fc, _op(vt, "lt_u"), select())
        emit!(fc, _op(vt, "shr_s"))
        emit_norm!(fc, rt)
    end
end

# --- conversions ------------------------------------------------------------

function emit_intconvert!(fc, kind::Symbol, rt, args)
    # args = (Type, x)
    dstT = rt
    srcT, rs = _intty(fc, args[2])
    rd = scalar_repr(dstT)
    rd === nothing && throw(CompileError("unsupported conversion target $dstT"))
    emit_value!(fc, args[2])
    if kind === :zext
        emit_zeroext!(fc, srcT)
        rs.vt == I32 && rd.vt == I64 && emit!(fc, Inst(:i64_extend_i32_u))
    elseif kind === :sext
        # sext interprets the source bits as signed regardless of the repr's
        # signedness (sext_int(Int64, 0xff) == -1); Bool is natively an 8-bit
        # 0/1 so it needs no extension.
        emit_signext!(fc, srcT)
        rs.vt == I32 && rd.vt == I64 && emit!(fc, Inst(:i64_extend_i32_s))
    else # trunc
        rs.vt == I64 && rd.vt == I32 && emit!(fc, Inst(:i32_wrap_i64))
        rs.vt == I32 && rd.vt == I64 &&
            emit!(fc, rs.signed ? Inst(:i64_extend_i32_s) : Inst(:i64_extend_i32_u))
    end
    emit_norm!(fc, dstT)
end

# --- the dispatch table ------------------------------------------------------

const INTRINSIC_HANDLERS = Dict{Symbol,Function}()

function _reg!(f, names...)
    for n in names
        INTRINSIC_HANDLERS[n] = f
    end
end

_reg!((fc, rt, args) -> emit_binop!(fc, "add", rt, args), :add_int)
_reg!((fc, rt, args) -> emit_binop!(fc, "sub", rt, args), :sub_int)
_reg!((fc, rt, args) -> emit_binop!(fc, "mul", rt, args), :mul_int)
_reg!((fc, rt, args) -> emit_binop!(fc, "and", rt, args; norm=false), :and_int)
_reg!((fc, rt, args) -> emit_binop!(fc, "or", rt, args; norm=false), :or_int)
_reg!((fc, rt, args) -> emit_binop!(fc, "xor", rt, args), :xor_int)
"""A Julia error point: catchable tag-throw inside try regions, trap outside."""
function emit_trap_or_throw!(fc)
    if fc.protected
        emit!(fc, ref_null(AnyHT), throw_(0))
    else
        emit!(fc, unreachable())
    end
end

"""
Division/remainder with Julia's error semantics. Outside protected regions the
native wasm traps (÷0, and typemin÷-1 for div_s at storage width) suffice;
inside try/catch the conditions are guarded explicitly so they raise the
catchable exception tag. Sub-word signed div overflow is always guarded (wasm
computes at i32 width and would silently wrap under renormalization).
"""
function emit_div!(fc, rt, args, name::String, signed::Bool)
    T, r = _intty(fc, args[1])
    vt = r.vt
    need_ovf = name == "div_s" && r.signed && (r.bits < 32 || fc.protected)
    need_zero = fc.protected
    if !(need_ovf || need_zero)
        if signed
            emit_binop!(fc, name, rt, args)
        else
            emit_value!(fc, args[1]); emit_zeroext!(fc, T)
            emit_value!(fc, args[2]); emit_zeroext!(fc, T)
            emit!(fc, _op(vt, name))
            emit_norm!(fc, rt)
        end
        return
    end
    sa = scratch_local!(fc, vt)
    sb = scratch_local!(fc, vt)
    emit_value!(fc, args[1]); signed || emit_zeroext!(fc, T); emit!(fc, local_set(sa))
    emit_value!(fc, args[2]); signed || emit_zeroext!(fc, T); emit!(fc, local_set(sb))
    if need_zero
        emit!(fc, local_get(sb), _op(vt, "eqz"), if_())
        emit_trap_or_throw!(fc)
        emit!(fc, end_())
    end
    if need_ovf
        lo = r.bits == 64 ? typemin(Int64) : r.bits == 32 ? Int64(typemin(Int32)) :
             r.bits == 16 ? Int64(-32768) : Int64(-128)
        emit!(fc, local_get(sb), _const(vt, -1), _op(vt, "eq"),
              local_get(sa), _const(vt, lo), _op(vt, "eq"), Inst(:i32_and), if_())
        emit_trap_or_throw!(fc)
        emit!(fc, end_())
    end
    emit!(fc, local_get(sa), local_get(sb), _op(vt, name))
    emit_norm!(fc, rt)
end

_reg!((fc, rt, args) -> emit_div!(fc, rt, args, "div_s", true),
      :sdiv_int, :checked_sdiv_int)
# rem never overflows (typemin % -1 == 0 both natively and in wasm rem_s)
_reg!((fc, rt, args) -> emit_div!(fc, rt, args, "rem_s", true),
      :srem_int, :checked_srem_int)
_reg!((fc, rt, args) -> emit_div!(fc, rt, args, "div_u", false),
      :udiv_int, :checked_udiv_int)
_reg!((fc, rt, args) -> emit_div!(fc, rt, args, "rem_u", false),
      :urem_int, :checked_urem_int)

_reg!(:neg_int) do fc, rt, args
    T, r = _intty(fc, args[1])
    emit!(fc, _const(r.vt, 0))
    emit_value!(fc, args[1])
    emit!(fc, _op(r.vt, "sub"))
    emit_norm!(fc, rt)
end

_reg!(:not_int) do fc, rt, args
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    if T === Bool
        emit!(fc, Inst(:i32_eqz))
    else
        emit!(fc, _const(r.vt, -1))
        emit!(fc, _op(r.vt, "xor"))
        emit_norm!(fc, rt)
    end
end

_reg!((fc, rt, args) -> emit_cmp!(fc, "eq", args), :eq_int)
_reg!((fc, rt, args) -> emit_cmp!(fc, "ne", args), :ne_int)
_reg!((fc, rt, args) -> emit_cmp!(fc, "lt_s", args; signed_fix=true), :slt_int)
_reg!((fc, rt, args) -> emit_cmp!(fc, "le_s", args; signed_fix=true), :sle_int)
_reg!((fc, rt, args) -> emit_cmp!(fc, "lt_u", args; unsigned_fix=true), :ult_int)
_reg!((fc, rt, args) -> emit_cmp!(fc, "le_u", args; unsigned_fix=true), :ule_int)

_reg!((fc, rt, args) -> emit_shift!(fc, :shl, rt, args), :shl_int)
_reg!((fc, rt, args) -> emit_shift!(fc, :lshr, rt, args), :lshr_int)
_reg!((fc, rt, args) -> emit_shift!(fc, :ashr, rt, args), :ashr_int)

_reg!(:ctlz_int) do fc, rt, args
    T, r = _intty(fc, args[1])
    if r.bits >= 32
        emit_value!(fc, args[1])
        emit!(fc, _op(r.vt, "clz"))
    else
        emit_value!(fc, args[1]); emit_zeroext!(fc, T)
        emit!(fc, Inst(:i32_clz), i32_const(32 - r.bits), Inst(:i32_sub))
    end
    emit_norm!(fc, rt)
end
_reg!(:cttz_int) do fc, rt, args
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    if r.bits >= 32
        emit!(fc, _op(r.vt, "ctz"))
    else
        emit_zeroext!(fc, T)
        emit!(fc, i32_const(1 << r.bits), Inst(:i32_or), Inst(:i32_ctz))
    end
    emit_norm!(fc, rt)
end
_reg!(:bswap_int) do fc, rt, args
    # no wasm byte-swap op: shift/mask ladder at the logical width
    T, r = _intty(fc, args[1])
    vt = r.vt
    x = scratch_local!(fc, vt)
    emit_value!(fc, args[1])
    r.bits < 32 && emit_zeroext!(fc, T)
    emit!(fc, local_set(x))
    if r.bits == 16
        emit!(fc, local_get(x), i32_const(8), Inst(:i32_shl),
              i32_const(0xff00), Inst(:i32_and),
              local_get(x), i32_const(8), Inst(:i32_shr_u),
              Inst(:i32_or))
    elseif r.bits == 8
        emit!(fc, local_get(x))
    else
        masks = vt == I64 ?
            [(8, 0x00FF00FF00FF00FF), (16, 0x0000FFFF0000FFFF), (32, nothing)] :
            [(8, UInt64(0x00FF00FF)), (16, nothing)]
        for (sh, mask) in masks
            if mask === nothing   # final half-width swap: pure rotate
                emit!(fc, local_get(x), _const(vt, sh), Inst(Symbol(_p(vt), "_rotl")),
                      local_set(x))
            else
                emit!(fc, local_get(x), _const(vt, mask), _op(vt, "and"),
                      _const(vt, sh), _op(vt, "shl"),
                      local_get(x), _const(vt, sh), _op(vt, "shr_u"),
                      _const(vt, mask), _op(vt, "and"),
                      _op(vt, "or"), local_set(x))
            end
        end
        emit!(fc, local_get(x))
    end
    emit_norm!(fc, rt)
end

_reg!(:ctpop_int) do fc, rt, args
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1])
    r.bits < 32 && emit_zeroext!(fc, T)
    emit!(fc, _op(r.vt, "popcnt"))
    emit_norm!(fc, rt)
end

_reg!(:flipsign_int) do fc, rt, args
    # flipsign(x, y) = y >= 0 ? x : -x  ==  (x ⊻ s) - s  with s = y >> (bits-1)
    T, r = _intty(fc, args[1])
    s = scratch_local!(fc, r.vt)
    emit_value!(fc, args[2])
    emit!(fc, _const(r.vt, (r.vt == I64 ? 63 : 31)))
    emit!(fc, _op(r.vt, "shr_s"), local_set(s))
    emit_value!(fc, args[1])
    emit!(fc, local_get(s), _op(r.vt, "xor"), local_get(s), _op(r.vt, "sub"))
    emit_norm!(fc, rt)
end

_reg!(:abs_int) do fc, rt, args
    # abs(x) = (x ⊻ s) - s  with s = x >> (bits-1)
    T, r = _intty(fc, args[1])
    s = scratch_local!(fc, r.vt)
    s2 = scratch_local!(fc, r.vt)
    emit_value!(fc, args[1])
    emit!(fc, local_tee(s))
    emit!(fc, _const(r.vt, (r.vt == I64 ? 63 : 31)))
    emit!(fc, _op(r.vt, "shr_s"), local_set(s2))
    emit!(fc, local_get(s), local_get(s2), _op(r.vt, "xor"),
          local_get(s2), _op(r.vt, "sub"))
    emit_norm!(fc, rt)
end

# integer conversions: args are (Type, x)
_reg!((fc, rt, args) -> emit_intconvert!(fc, :zext, rt, args), :zext_int)
_reg!((fc, rt, args) -> emit_intconvert!(fc, :sext, rt, args), :sext_int)
_reg!((fc, rt, args) -> emit_intconvert!(fc, :trunc, rt, args), :trunc_int)

# --- floats ------------------------------------------------------------------

for (jl, wasm) in [(:add_float, "add"), (:sub_float, "sub"), (:mul_float, "mul"),
                   (:div_float, "div"), (:copysign_float, "copysign"),
                   (:add_float_fast, "add"), (:sub_float_fast, "sub"),
                   (:mul_float_fast, "mul"), (:div_float_fast, "div")]
    _reg!((fc, rt, args) -> emit_binop!(fc, wasm, rt, args; norm=false), jl)
end
for (jl, wasm) in [(:neg_float, "neg"), (:abs_float, "abs"), (:sqrt_llvm, "sqrt"),
                   (:sqrt_llvm_fast, "sqrt"), (:ceil_llvm, "ceil"), (:floor_llvm, "floor"),
                   (:trunc_llvm, "trunc"), (:rint_llvm, "nearest"), (:neg_float_fast, "neg")]
    _reg!((fc, rt, args) -> emit_unop!(fc, wasm, rt, args; norm=false), jl)
end
for (jl, wasm) in [(:eq_float, "eq"), (:ne_float, "ne"), (:lt_float, "lt"),
                   (:le_float, "le"), (:eq_float_fast, "eq"), (:ne_float_fast, "ne"),
                   (:lt_float_fast, "lt"), (:le_float_fast, "le")]
    _reg!((fc, rt, args) -> emit_cmp!(fc, wasm, args), jl)
end

_reg!(:fpiseq) do fc, rt, args
    T, r = _intty(fc, args[1])
    re = r.vt == F64 ? Inst(:i64_reinterpret_f64) : Inst(:i32_reinterpret_f32)
    eq = r.vt == F64 ? Inst(:i64_eq) : Inst(:i32_eq)
    emit_value!(fc, args[1]); emit!(fc, re)
    emit_value!(fc, args[2]); emit!(fc, re)
    emit!(fc, eq)
end

_reg!(:muladd_float) do fc, rt, args
    # DOCUMENTED LATITUDE: Julia's muladd permits either fused (one rounding)
    # or unfused (two roundings) evaluation. Native x86-64 fuses to fma; wasm
    # has no fma instruction, so this emits mul+add and can differ from native
    # in the last ulp for catastrophic cancellation cases. Value-exact
    # differential tests must accept either rounding for muladd.
    T, r = _intty(fc, args[1])
    emit_value!(fc, args[1]); emit_value!(fc, args[2])
    emit!(fc, _op(r.vt, "mul"))
    emit_value!(fc, args[3])
    emit!(fc, _op(r.vt, "add"))
end

_reg!(:have_fma) do fc, rt, args
    emit!(fc, i32_const(0))
end

# float <-> int conversions: args are (Type, x)
#
# DOCUMENTED LATITUDE (fptosi/fptoui): Julia's unsafe_trunc returns "an
# arbitrary value" for NaN/out-of-range inputs. We emit the deterministic
# saturating wasm instructions (NaN -> 0, overflow -> typemin/typemax at
# storage width); native x86 returns the cvttsd2si sentinel (INT_MIN, or
# all-ones for AVX-512 unsigned), and other hosts differ again. Checked
# conversions (Int64(x), trunc, round) raise/trap identically on both sides;
# only unsafe_trunc on inexact inputs may diverge from the native value and
# must be excluded from value-exact differential corpora.
_reg!(:sitofp) do fc, rt, args
    srcT, rs = _intty(fc, args[2])
    rd = scalar_repr(rt)
    # signed interpretation of the source bits regardless of repr signedness
    # (sitofp(Float64, 0xff) == -1.0)
    emit_value!(fc, args[2]); emit_signext!(fc, srcT)
    suffix = rs.vt == I64 ? "convert_i64_s" : "convert_i32_s"
    emit!(fc, _op(rd.vt, suffix))
end
_reg!(:uitofp) do fc, rt, args
    srcT, rs = _intty(fc, args[2])
    rd = scalar_repr(rt)
    emit_value!(fc, args[2]); emit_zeroext!(fc, srcT)
    suffix = rs.vt == I64 ? "convert_i64_u" : "convert_i32_u"
    emit!(fc, _op(rd.vt, suffix))
end
_reg!(:fptosi) do fc, rt, args
    srcT, rs = _intty(fc, args[2])
    rd = scalar_repr(rt)
    emit_value!(fc, args[2])
    emit!(fc, Inst(Symbol(_p(rd.vt == I32 ? I32 : I64), "_trunc_sat_", _p(rs.vt), "_s")))
    emit_norm!(fc, rt)
end
_reg!(:fptoui) do fc, rt, args
    srcT, rs = _intty(fc, args[2])
    rd = scalar_repr(rt)
    emit_value!(fc, args[2])
    emit!(fc, Inst(Symbol(_p(rd.vt == I32 ? I32 : I64), "_trunc_sat_", _p(rs.vt), "_u")))
    emit_norm!(fc, rt)
end
_reg!(:fptrunc) do fc, rt, args
    emit_value!(fc, args[2])
    rt === Float32 || throw(CompileError("fptrunc to $rt"))
    emit!(fc, Inst(:f32_demote_f64))
end
_reg!(:fpext) do fc, rt, args
    emit_value!(fc, args[2])
    rt === Float64 || throw(CompileError("fpext to $rt"))
    emit!(fc, Inst(:f64_promote_f32))
end

# --- 128-bit integers ---------------------------------------------------------
# Int128/UInt128 live in a {lo::i64, hi::i64} GC struct (see gc_i128!). Only
# the operations Base's checked range arithmetic needs are implemented;
# everything else fails loudly.

_is_i128(@nospecialize T) = T === Int128 || T === UInt128

"""Load an i128 value's halves into two scratch i64 locals; returns (lo, hi)."""
function _i128_load!(fc, @nospecialize ref)
    t128 = gc_i128!(fc.mc)
    r = scratch_local!(fc, RefType(true, HeapType(t128)))
    lo = scratch_local!(fc, I64)
    hi = scratch_local!(fc, I64)
    emit_value!(fc, ref)
    emit!(fc, local_tee(r), struct_get(t128, 0), local_set(lo),
          local_get(r), struct_get(t128, 1), local_set(hi))
    return lo, hi
end

function emit_i128!(fc, name::Symbol, @nospecialize(rt), args)
    t128 = gc_i128!(fc.mc)
    if name === :sext_int || name === :zext_int
        srcT = argtype(fc, args[2])
        if _is_i128(srcT)   # 128 -> 128 reinterpretation
            emit_value!(fc, args[2])
            return
        end
        r = scalar_repr(srcT)
        r === nothing && throw(CompileError("$name to 128 bits from $srcT"))
        emit_value!(fc, args[2])
        if name === :sext_int
            emit_signext!(fc, srcT)
            r.vt == I32 && emit!(fc, Inst(:i64_extend_i32_s))
            lo = scratch_local!(fc, I64)
            emit!(fc, local_tee(lo), local_get(lo),
                  i64_const(63), Inst(:i64_shr_s), struct_new(t128))
        else
            emit_zeroext!(fc, srcT)
            r.vt == I32 && emit!(fc, Inst(:i64_extend_i32_u))
            emit!(fc, i64_const(0), struct_new(t128))
        end
    elseif name === :trunc_int
        # 128 -> narrow: take the low half
        _is_i128(argtype(fc, args[2])) ||
            throw(CompileError("trunc_int with 128-bit result unsupported"))
        rd = scalar_repr(rt)
        rd === nothing && throw(CompileError("trunc_int 128 -> $rt"))
        emit_value!(fc, args[2])
        emit!(fc, struct_get(t128, 0))
        rd.vt == I32 && emit!(fc, Inst(:i32_wrap_i64))
        emit_norm!(fc, rt)
    elseif name === :add_int || name === :sub_int || name === :neg_int
        local alo, ahi, blo, bhi
        if name === :neg_int
            z = scratch_local!(fc, I64)
            emit!(fc, i64_const(0), local_set(z))
            alo = ahi = z
            blo, bhi = _i128_load!(fc, args[1])
        else
            alo, ahi = _i128_load!(fc, args[1])
            blo, bhi = _i128_load!(fc, args[2])
        end
        sub = name !== :add_int
        lo = scratch_local!(fc, I64)
        op = sub ? Inst(:i64_sub) : Inst(:i64_add)
        emit!(fc, local_get(alo), local_get(blo), op, local_tee(lo))
        # carry = lo <u alo (add) | borrow = alo <u blo (sub), as i64 0/1
        if sub
            emit!(fc, local_get(ahi), local_get(bhi), Inst(:i64_sub),
                  local_get(alo), local_get(blo), Inst(:i64_lt_u),
                  Inst(:i64_extend_i32_u), Inst(:i64_sub))
        else
            emit!(fc, local_get(ahi), local_get(bhi), Inst(:i64_add),
                  local_get(lo), local_get(alo), Inst(:i64_lt_u),
                  Inst(:i64_extend_i32_u), Inst(:i64_add))
        end
        # stack: [lo, hi]
        emit!(fc, struct_new(t128))
    elseif name in (:and_int, :or_int, :xor_int)
        opn = name === :and_int ? "and" : name === :or_int ? "or" : "xor"
        alo, ahi = _i128_load!(fc, args[1])
        blo, bhi = _i128_load!(fc, args[2])
        emit!(fc, local_get(alo), local_get(blo), _op(I64, opn),
              local_get(ahi), local_get(bhi), _op(I64, opn), struct_new(t128))
    elseif name === :not_int
        alo, ahi = _i128_load!(fc, args[1])
        emit!(fc, local_get(alo), i64_const(-1), Inst(:i64_xor),
              local_get(ahi), i64_const(-1), Inst(:i64_xor), struct_new(t128))
    elseif name in (:eq_int, :ne_int)
        alo, ahi = _i128_load!(fc, args[1])
        blo, bhi = _i128_load!(fc, args[2])
        emit!(fc, local_get(alo), local_get(blo), Inst(:i64_eq),
              local_get(ahi), local_get(bhi), Inst(:i64_eq), Inst(:i32_and))
        name === :ne_int && emit!(fc, Inst(:i32_eqz))
    elseif name in (:slt_int, :sle_int, :ult_int, :ule_int)
        alo, ahi = _i128_load!(fc, args[1])
        blo, bhi = _i128_load!(fc, args[2])
        hicmp = name in (:slt_int, :sle_int) ? Inst(:i64_lt_s) : Inst(:i64_lt_u)
        locmp = name in (:slt_int, :ult_int) ? Inst(:i64_lt_u) : Inst(:i64_le_u)
        emit!(fc, local_get(ahi), local_get(bhi), hicmp,
              local_get(ahi), local_get(bhi), Inst(:i64_eq),
              local_get(alo), local_get(blo), locmp, Inst(:i32_and),
              Inst(:i32_or))
    else
        throw(CompileError("unsupported 128-bit intrinsic $name"))
    end
end

# --- checked arithmetic with overflow flag ----------------------------------
# checked_{s,u}{add,sub,mul}_int return (value, overflowed::Bool); the compiler
# materializes both into a pair of locals (see ssapair handling).

const CHECKED_PAIR = Dict{Symbol,Tuple{Symbol,Bool}}(
    :checked_sadd_int => (:add, true), :checked_uadd_int => (:add, false),
    :checked_ssub_int => (:sub, true), :checked_usub_int => (:sub, false),
    :checked_smul_int => (:mul, true), :checked_umul_int => (:mul, false),
)

function emit_checked!(fc, kind::Symbol, signed::Bool, args, vloc::Int, floc::Int)
    T, r = _intty(fc, args[1])
    if r.vt == I32
        # widen to i64; flag = widened result does not round-trip
        ext = r.signed ? Inst(:i64_extend_i32_s) : Inst(:i64_extend_i32_u)
        p = scratch_local!(fc, I64)
        emit_value!(fc, args[1]); emit!(fc, ext)
        emit_value!(fc, args[2]); emit!(fc, ext)
        emit!(fc, _op(I64, string(kind)), local_set(p))
        emit!(fc, local_get(p), Inst(:i32_wrap_i64))
        emit_norm!(fc, T)
        emit!(fc, local_set(vloc))
        emit!(fc, local_get(p), local_get(vloc), ext, Inst(:i64_ne), local_set(floc))
        return
    end
    sa = scratch_local!(fc, I64)
    sb = scratch_local!(fc, I64)
    emit_value!(fc, args[1]); emit!(fc, local_set(sa))
    emit_value!(fc, args[2]); emit!(fc, local_set(sb))
    emit!(fc, local_get(sa), local_get(sb), _op(I64, string(kind)), local_set(vloc))
    if kind === :add
        if signed   # ((p ⊻ a) & (p ⊻ b)) < 0
            emit!(fc, local_get(vloc), local_get(sa), Inst(:i64_xor),
                  local_get(vloc), local_get(sb), Inst(:i64_xor), Inst(:i64_and),
                  i64_const(0), Inst(:i64_lt_s), local_set(floc))
        else        # p <u a
            emit!(fc, local_get(vloc), local_get(sa), Inst(:i64_lt_u), local_set(floc))
        end
    elseif kind === :sub
        if signed   # ((a ⊻ b) & (a ⊻ p)) < 0
            emit!(fc, local_get(sa), local_get(sb), Inst(:i64_xor),
                  local_get(sa), local_get(vloc), Inst(:i64_xor), Inst(:i64_and),
                  i64_const(0), Inst(:i64_lt_s), local_set(floc))
        else        # a <u b
            emit!(fc, local_get(sa), local_get(sb), Inst(:i64_lt_u), local_set(floc))
        end
    else # mul: division-based check, guarding the trapping cases
        emit!(fc, local_get(sa), Inst(:i64_eqz), if_(I32))
        emit!(fc, i32_const(0))
        emit!(fc, else_())
        if signed
            emit!(fc, local_get(sa), i64_const(-1), Inst(:i64_eq), if_(I32))
            emit!(fc, local_get(sb), i64_const(typemin(Int64)), Inst(:i64_eq))
            emit!(fc, else_())
            emit!(fc, local_get(vloc), local_get(sa), Inst(:i64_div_s),
                  local_get(sb), Inst(:i64_ne))
            emit!(fc, end_())
        else
            emit!(fc, local_get(vloc), local_get(sa), Inst(:i64_div_u),
                  local_get(sb), Inst(:i64_ne))
        end
        emit!(fc, end_())
        emit!(fc, local_set(floc))
    end
end

_reg!(:bitcast) do fc, rt, args
    srcT = argtype(fc, args[2])
    rs, rd = scalar_repr(srcT), scalar_repr(rt)
    (rs === nothing || rd === nothing) && throw(CompileError("bitcast $srcT -> $rt"))
    emit_value!(fc, args[2])
    if rs.vt == rd.vt || (rs.vt == I32 && rd.vt == I32)
        emit_norm!(fc, rt)
    elseif rs.vt == F64 && rd.vt == I64
        emit!(fc, Inst(:i64_reinterpret_f64))
    elseif rs.vt == I64 && rd.vt == F64
        emit!(fc, Inst(:f64_reinterpret_i64))
    elseif rs.vt == F32 && rd.vt == I32
        emit!(fc, Inst(:i32_reinterpret_f32))
    elseif rs.vt == I32 && rd.vt == F32
        emit_zeroext!(fc, srcT)
        emit!(fc, Inst(:f32_reinterpret_i32))
    else
        throw(CompileError("bitcast $srcT -> $rt"))
    end
end
