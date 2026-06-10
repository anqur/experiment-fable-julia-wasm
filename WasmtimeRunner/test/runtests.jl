using Test
using WasmtimeRunner
using WasmTools
using WasmTools.Instructions

# Build wasm binaries with WasmTools and execute them with wasmtime.

function add_module()
    m = WasmModule()
    addfunc!(m, "add", FuncType([I64, I64], [I64]), ValType[],
             [local_get(0), local_get(1), i64_add()]; export_name="add")
    addfunc!(m, "div", FuncType([I64, I64], [I64]), ValType[],
             [local_get(0), local_get(1), i64_div_s()]; export_name="div")
    return encode(m)
end

@testset "load, validate, call" begin
    eng = Engine()
    validate_module(eng, add_module())
    @test_throws WasmtimeError validate_module(eng, UInt8[0, 1, 2, 3])

    store = Store(eng)
    mod = CompiledModule(eng, add_module())
    inst = instantiate(store, mod)
    ex = exports(inst)
    @test Set(keys(ex)) == Set(["add", "div"])
    add = ex["add"]
    @test add isa WasmFunc
    @test add.params == [:i64, :i64] && add.results == [:i64]
    @test add(2, 3) === Int64(5)
    @test add(typemax(Int64), 1) === typemin(Int64)   # wrapping
    @test inst["div"](7, 2) === Int64(3)
end

@testset "traps" begin
    eng = Engine()
    store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, add_module()))
    div = inst["div"]
    @test_throws WasmTrap div(1, 0)
    err = try div(1, 0); nothing catch e; e end
    @test occursin("divide by zero", err.msg)
    @test_throws WasmTrap div(typemin(Int64), -1)   # integer overflow trap

    m = WasmModule()
    addfunc!(m, "boom", FuncType(ValType[], ValType[]), ValType[],
             [unreachable()]; export_name="boom")
    inst2 = instantiate(store, CompiledModule(eng, encode(m)))
    @test_throws WasmTrap inst2["boom"]()
end

@testset "floats and multiple results" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    addfunc!(m, "fma", FuncType([F64, F64, F64], [F64]), ValType[],
             [local_get(0), local_get(1), f64_mul(), local_get(2), f64_add()];
             export_name="fma")
    addfunc!(m, "divmod", FuncType([I32, I32], [I32, I32]), ValType[],
             [local_get(0), local_get(1), i32_div_s(),
              local_get(0), local_get(1), i32_rem_s()]; export_name="divmod")
    inst = instantiate(store, CompiledModule(eng, encode(m)))
    @test inst["fma"](2.0, 3.0, 1.0) === 7.0
    @test inst["divmod"](7, 2) === (Int32(3), Int32(1))
end

@testset "host functions" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    importfunc!(m, "host", "mul2", FuncType([I64], [I64]))
    importfunc!(m, "host", "logval", FuncType([I64], ValType[]))
    addfunc!(m, "go", FuncType([I64], [I64]), ValType[],
             [local_get(0), call(0), local_get(0), call(1)]; export_name="go")
    mod = CompiledModule(eng, encode(m))

    logged = Int64[]
    lk = Linker(eng)
    define_func!((x) -> 2x, lk, "host", "mul2", [:i64], [:i64])
    define_func!(lk, "host", "logval", [:i64], Symbol[]) do x
        push!(logged, x)
        nothing
    end
    inst = instantiate(lk, store, mod)
    @test inst["go"](21) === Int64(42)
    @test logged == [21]

    # Julia exception inside host function becomes a wasm trap
    m2 = WasmModule()
    importfunc!(m2, "host", "fail", FuncType(ValType[], [I64]))
    addfunc!(m2, "go", FuncType(ValType[], [I64]), ValType[], [call(0)];
             export_name="go")
    lk2 = Linker(eng)
    define_func!(() -> error("kaboom from julia"), lk2, "host", "fail", Symbol[], [:i64])
    inst2 = instantiate(lk2, store, CompiledModule(eng, encode(m2)))
    err = try inst2["go"](); nothing catch e; e end
    # wasmtime surfaces host-created traps as errors with a wasm backtrace
    @test err isa Union{WasmTrap,WasmtimeError}
    @test occursin("kaboom from julia", err.msg)
end

@testset "externref: binding Julia values" begin
    eng = Engine(); store = Store(eng)
    # wasm shuffles externrefs around; host functions observe Julia objects.
    m = WasmModule()
    importfunc!(m, "host", "combine", FuncType([ExternRefT, ExternRefT], [ExternRefT]))
    # pass two externrefs through wasm into the host and return its result
    addfunc!(m, "apply", FuncType([ExternRefT, ExternRefT], [ExternRefT]), ValType[],
             [local_get(0), local_get(1), call(0)]; export_name="apply")
    # roundtrip an externref untouched
    addfunc!(m, "ident", FuncType([ExternRefT], [ExternRefT]), ValType[],
             [local_get(0)]; export_name="ident")
    # null externref
    addfunc!(m, "mknull", FuncType(ValType[], [ExternRefT]), ValType[],
             [ref_null(ExternHT)]; export_name="mknull")

    lk = Linker(eng)
    define_func!(lk, "host", "combine", [:externref, :externref], [:externref]) do a, b
        (a, b)   # arbitrary Julia structure
    end
    inst = instantiate(lk, store, CompiledModule(eng, encode(m)))

    x = [1, 2, 3]
    y = Dict(:a => 1)
    @test inst["ident"](x) === x
    res = inst["apply"](x, y)
    @test res isa Tuple && res[1] === x && res[2] === y
    @test inst["ident"](nothing) === nothing
    @test inst["mknull"]() === nothing
    store_gc!(store)
end

@testset "globals and memory" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    push!(m.globals, Global(GlobalType(I64, true), [i64_const(10)]))
    push!(m.exports, Export("g", :global, 0))
    push!(m.mems, MemoryType(Limits(1, 2)))
    push!(m.exports, Export("mem", :memory, 0))
    push!(m.datas, Data(:active, 0, [i32_const(4)], UInt8[0xAB, 0xCD]))
    addfunc!(m, "bump", FuncType(ValType[], [I64]), ValType[],
             [global_get(0), i64_const(1), i64_add(), global_set(0), global_get(0)];
             export_name="bump")
    inst = instantiate(store, CompiledModule(eng, encode(m)))
    g = inst["g"]
    @test g isa WasmGlobal
    @test g[] === Int64(10)
    @test inst["bump"]() === Int64(11)
    @test g[] === Int64(11)
    g[] = 100
    @test inst["bump"]() === Int64(101)
    mem = inst["mem"]
    @test mem isa WasmMemory
    bytes = read(mem)
    @test length(bytes) == 65536
    @test bytes[5] == 0xAB && bytes[6] == 0xCD
end

@testset "GC module execution" begin
    # WasmGC struct allocation/access fully inside wasm, scalar boundary.
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    pair = addtype!(m, StructType([FieldType(I64, false), FieldType(I64, true)]))
    arr = addtype!(m, ArrayType(FieldType(I64, true)))
    # makeAndSum(a, b) = let p = struct(a, b); arr = [a, b, a+b]; p.0 + p.1 + arr[2]
    body = [
        local_get(0), local_get(1), struct_new(pair),
        local_set(2),
        local_get(2), struct_get(pair, 0),
        local_get(2), struct_get(pair, 1),
        i64_add(),
        # array of 3 elems, default 0, then set [2] = a+b
        i64_const(0), i32_const(3), array_new(arr),
        local_set(3),
        local_get(3), i32_const(2), local_get(0), local_get(1), i64_add(), array_set(arr),
        local_get(3), i32_const(2), array_get(arr),
        i64_add(),
    ]
    addfunc!(m, "makeAndSum", FuncType([I64, I64], [I64]),
             ValType[typeref(pair; nullable=true), typeref(arr; nullable=true)],
             body; export_name="makeAndSum")
    inst = instantiate(store, CompiledModule(eng, encode(m)))
    @test inst["makeAndSum"](5, 7) === Int64(24)   # (5+7) + (5+7)
    store_gc!(store)
    @test inst["makeAndSum"](1, 2) === Int64(6)
end
