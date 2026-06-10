# Independent verification of the Char representation finding.
# Differential test: native Julia vs wasmtime execution.
using WasmCodegen, WasmtimeRunner

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
    return function (args...)
        wire = Any[WasmCodegen.to_wire(T, a) for (T, a) in zip(argts, args)]
        raw = wf(wire...)
        return raw
    end
end

charcp(c::Char)   = UInt32(c)                          # codepoint decode (Base)
charbits(c::Char) = reinterpret(UInt32, c)             # bitcast
zextchar(c::Char) = Core.Intrinsics.zext_int(UInt64, c)
charround(c::Char) = c                                  # identity roundtrip via wire

fails = 0
for (name, f, RT) in (("UInt32(c)", charcp, UInt32),
                      ("reinterpret(UInt32,c)", charbits, UInt32),
                      ("zext_int(UInt64,c)", zextchar, UInt64))
    wf = try
        wasm_callable(f, Tuple{Char})
    catch err
        println("$name: COMPILE FAILED: ", err)
        continue
    end
    for c in ('a', 'λ', '∀')
        native = f(c)
        raw = wf(c)
        wasmval = WasmCodegen.from_wire(RT, raw)
        agree = isequal(native, wasmval)
        agree || global fails += 1
        println("$name  c=$(repr(c))  native=$(repr(native))  wasm=$(repr(wasmval))  ",
                agree ? "OK" : "MISMATCH")
    end
end

# Char identity roundtrip through the wire conventions
wid = wasm_callable(charround, Tuple{Char})
for c in ('a', 'λ')
    native = charround(c)
    wasmval = WasmCodegen.from_wire(Char, wid(c))
    agree = isequal(native, wasmval)
    agree || global fails += 1
    println("identity(c)  c=$(repr(c))  native=$(repr(native))  wasm=$(repr(wasmval)) (bits $(repr(reinterpret(UInt32, wasmval))))  ",
            agree ? "OK" : "MISMATCH")
end

println(fails == 0 ? "ALL AGREE" : "$fails MISMATCHES")
