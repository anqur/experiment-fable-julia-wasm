# Dump IR for conversion + float-math + bit-op intrinsics to confirm arg order.
# Usage: julia +nightly --project=. NativeCodegen/test/debug_conv_ir.jl

using NativeCodegen: NCGInterp

function sitofp_demo(x::Int64)::Float64; return Float64(x); end
function uitofp_demo(x::UInt64)::Float64; return Float64(x); end
function fptosi_demo(x::Float64)::Int64; return Int64(trunc(x)); end
function fptoui_demo(x::Float64)::UInt64; return UInt64(trunc(x)); end
function fpext_demo(x::Float32)::Float64; return Float64(x); end
function fptrunc_demo(x::Float64)::Float32; return Float32(x); end
function sext_demo(x::Int8)::Int64; return Int64(x); end        # sext_int
function zext_demo(x::UInt8)::UInt64; return UInt64(x); end      # zext_int
function trunc_demo(x::Int64)::Int8; return Int8(x); end         # trunc_int
function sqrt_demo(x::Float64)::Float64; return sqrt(x); end
function bswap_demo(x::UInt16)::UInt16; return bswap(x); end
function ctlz_demo(x::UInt8)::UInt8; return Base.lead_zeros(x); end
function flipsign_demo(x::Int64, y::Int64)::Int64; return flipsign(x, y); end
function absint_demo(x::Int64)::Int64; return abs(x); end

function dump_ir(f, argtypes, label)
    interp = NCGInterp()
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

dump_ir(sitofp_demo, Tuple{Int64}, "sitofp (Float64(x::Int64))")
dump_ir(uitofp_demo, Tuple{UInt64}, "uitofp (Float64(x::UInt64))")
dump_ir(fptosi_demo, Tuple{Float64}, "fptosi (Int64(trunc(x)))")
dump_ir(fptoui_demo, Tuple{Float64}, "fptoui (UInt64(trunc(x)))")
dump_ir(fpext_demo, Tuple{Float32}, "fpext (Float64(x::Float32))")
dump_ir(fptrunc_demo, Tuple{Float64}, "fptrunc (Float32(x::Float64))")
dump_ir(sext_demo, Tuple{Int8}, "sext_int (Int64(x::Int8))")
dump_ir(zext_demo, Tuple{UInt8}, "zext_int (UInt64(x::UInt8))")
dump_ir(trunc_demo, Tuple{Int64}, "trunc_int (Int8(x::Int64))")
dump_ir(sqrt_demo, Tuple{Float64}, "sqrt_llvm")
dump_ir(bswap_demo, Tuple{UInt16}, "bswap_int")
dump_ir(ctlz_demo, Tuple{UInt8}, "ctlz_int (lead_zeros)")
dump_ir(flipsign_demo, Tuple{Int64,Int64}, "flipsign_int")
dump_ir(absint_demo, Tuple{Int64}, "abs_int")

function lz_demo(x::UInt64)::UInt64; return leading_zeros(x); end
function tz_demo(x::UInt64)::UInt64; return trailing_zeros(x); end
function co_demo(x::UInt64)::UInt64; return count_ones(x); end
dump_ir(lz_demo, Tuple{UInt64}, "leading_zeros")
dump_ir(tz_demo, Tuple{UInt64}, "trailing_zeros")
dump_ir(co_demo, Tuple{UInt64}, "count_ones")
