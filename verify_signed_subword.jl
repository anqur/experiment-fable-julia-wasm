# Independent minimal verification: signed-interpretation intrinsics on
# unsigned sub-word reps (UInt8/UInt16). Differential: native Julia vs wasmtime.
using WasmCodegen, WasmtimeRunner, WasmTools

const ENGINE = Engine()

function wasm_callable(f, argtypes::Type{<:Tuple})
    comp = compile_wasm(f, argtypes)
    validate_module(ENGINE, comp.bytes)
    store = Store(ENGINE)
    lk = Linker(ENGINE)
    for (mod, name, params, results, thunk) in offload_imports(comp)
        define_func!(thunk, lk, mod, name, collect(Symbol, params), collect(Symbol, results))
    end
    inst = instantiate(lk, store, CompiledModule(ENGINE, comp.bytes))
    wf = inst[comp.entry]
    argts = collect(argtypes.parameters)
    return (args...) -> wf(Any[WasmCodegen.to_wire(T, a) for (T, a) in zip(argts, args)]...)
end

# direct Core.Intrinsics calls on unsigned sub-word types
ashru8(x::UInt8, n::Int64)   = Core.Intrinsics.ashr_int(x, n)
ashru16(x::UInt16, n::Int64) = Core.Intrinsics.ashr_int(x, n)
sltu8(x::UInt8, y::UInt8)    = Core.Intrinsics.slt_int(x, y)
sleu8(x::UInt8, y::UInt8)    = Core.Intrinsics.sle_int(x, y)
sltu16(x::UInt16, y::UInt16) = Core.Intrinsics.slt_int(x, y)
sextu8(x::UInt8)             = Core.Intrinsics.sext_int(Int64, x)
sextu16_32(x::UInt16)        = Core.Intrinsics.sext_int(Int32, x)
sitofpu8(x::UInt8)           = Core.Intrinsics.sitofp(Float64, x)
sitofpu16(x::UInt16)         = Core.Intrinsics.sitofp(Float64, x)

ndiff = 0
function check(name, f, argtypes, cases)
    global ndiff
    wf = wasm_callable(f, argtypes)
    for args in cases
        native = f(args...)
        wasmraw = wf(args...)
        wasm = WasmCodegen.from_wire(typeof(native), wasmraw)
        if !isequal(native, wasm)
            ndiff += 1
            println("DIFF[$name] args=$args  native=$(repr(native))  wasm=$(repr(wasm))")
        else
            println("  ok[$name] args=$args  -> $(repr(native))")
        end
    end
end

check("ashru8", ashru8, Tuple{UInt8,Int64},
      [(0x80, 1), (0xff, 100), (0x40, 1), (0x01, 0)])
check("ashru16", ashru16, Tuple{UInt16,Int64},
      [(0x8000, 1), (0xffff, 100), (0x0100, 4)])
check("sltu8", sltu8, Tuple{UInt8,UInt8},
      [(0x80, 0x01), (0x01, 0x80), (0x7f, 0x80), (0x05, 0x05)])
check("sleu8", sleu8, Tuple{UInt8,UInt8},
      [(0x80, 0x01), (0x01, 0x80), (0x05, 0x05)])
check("sltu16", sltu16, Tuple{UInt16,UInt16},
      [(0x8000, 0x0001), (0x0001, 0x8000)])
check("sextu8", sextu8, Tuple{UInt8}, [(0xff,), (0x80,), (0x7f,)])
check("sextu16_32", sextu16_32, Tuple{UInt16}, [(0xffff,), (0x7fff,)])
check("sitofpu8", sitofpu8, Tuple{UInt8}, [(0xff,), (0x80,), (0x10,)])
check("sitofpu16", sitofpu16, Tuple{UInt16}, [(0xffff,), (0x1234,)])

# control: same ops on signed sub-word types must agree (sanity that the
# harness itself is sound)
ashri8(x::Int8, n::Int64) = Core.Intrinsics.ashr_int(x, n)
slti8(x::Int8, y::Int8)   = Core.Intrinsics.slt_int(x, y)
check("ctrl_ashri8", ashri8, Tuple{Int8,Int64}, [(Int8(-128), 1), (Int8(64), 1)])
check("ctrl_slti8", slti8, Tuple{Int8,Int8}, [(Int8(-128), Int8(1)), (Int8(1), Int8(-128))])

println("\nTOTAL DIFFS: $ndiff")
exit(ndiff > 0 ? 42 : 0)
