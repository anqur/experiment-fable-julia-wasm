# Dump IR for checked-arithmetic intrinsics to confirm the ssapair + getfield shape.
# Usage: julia +nightly --project=. NativeCodegen/test/debug_checked_ir.jl

using WasmCodegen: WasmInterp

# Base.Checked entrypoints → checked_{s,u}{add,sub,mul}_int.
csadd(a::Int64, b::Int64)  = Base.Checked.add(a, b)
cssub(a::Int64, b::Int64)  = Base.Checked.sub(a, b)
csmul(a::Int64, b::Int64)  = Base.Checked.mul(a, b)
cuadd(a::UInt64, b::UInt64) = Base.Checked.add(a, b)
cusub(a::UInt64, b::UInt64) = Base.Checked.sub(a, b)
cumul(a::UInt64, b::UInt64) = Base.Checked.mul(a, b)
# 32-bit width.
csi32(a::Int32, b::Int32) = Base.Checked.add(a, b)
# Manual intrinsic (in case Base.Checked lowering differs).
raw_csa(a::Int64, b::Int64) = Core.Intrinsics.checked_sadd_int(a, b)

function dump_ir(f, argtypes, label)
    interp = WasmInterp()
    tt = Base.signature_type(f, argtypes)
    matches = Base._methods_by_ftype(tt, -1, interp.world)
    mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
    result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
    ir, _ = result[1]
    println("\n=== $label  ($argtypes) ===")
    for (i, stmt) in enumerate(ir.stmts)
        println("  [$i] $(stmt[:stmt]) :: $(stmt[:type])")
    end
end

dump_ir(csadd,  Tuple{Int64,Int64}, "checked_sadd (Int64)")
dump_ir(cssub,  Tuple{Int64,Int64}, "checked_ssub (Int64)")
dump_ir(csmul,  Tuple{Int64,Int64}, "checked_smul (Int64)")
dump_ir(cuadd,  Tuple{UInt64,UInt64}, "checked_uadd (UInt64)")
dump_ir(cusub,  Tuple{UInt64,UInt64}, "checked_usub (UInt64)")
dump_ir(cumul,  Tuple{UInt64,UInt64}, "checked_umul (UInt64)")
dump_ir(csi32,  Tuple{Int32,Int32}, "checked_sadd (Int32)")
dump_ir(raw_csa, Tuple{Int64,Int64}, "Core.Intrinsics.checked_sadd_int (raw)")

# Real usage: destructure (value, flag) and use both → forces getfield on the pair.
function use_sadd(a::Int64, b::Int64)
    r, flag = Core.Intrinsics.checked_sadd_int(a, b)
    return ifelse(flag, typemin(Int64), r)
end
dump_ir(use_sadd, Tuple{Int64,Int64}, "use_sadd (destructured, both fields used)")

# Only the value used (flag discarded) — common case for unchecked-by-default code.
function use_val_only(a::Int64, b::Int64)
    r, _ = Core.Intrinsics.checked_sadd_int(a, b)
    return r
end
dump_ir(use_val_only, Tuple{Int64,Int64}, "use_val_only (flag discarded)")
