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

# --- regression tests for audited findings -------------------------------------

@testset "externref roots are released (no leak)" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    addfunc!(m, "ident", FuncType([ExternRefT], [ExternRefT]), ValType[],
             [local_get(0)]; export_name="ident")
    push!(m.globals, Global(GlobalType(ExternRefT, true), [ref_null(ExternHT)]))
    push!(m.exports, Export("g", :global, 0))
    bytes = encode(m)
    inst = instantiate(store, CompiledModule(eng, bytes))
    ident = inst["ident"]

    # store.roots must not grow per call (it only retains host-function boxes)
    obj = [1, 2, 3]
    nroots0 = length(store.roots)
    for _ in 1:1000
        @assert ident(obj) === obj
    end
    @test length(store.roots) == nroots0

    # Julia-side boxes are registered while wasm can reach the value and
    # released once wasm's GC reclaims it (finalizer-based rooting).
    table_count(marker) = Base.@lock WasmtimeRunner._EXTERNREF_TABLE_LOCK begin
        count(b -> b.obj isa Tuple{Symbol,Int} && b.obj[1] === marker,
              collect(keys(WasmtimeRunner._EXTERNREF_TABLE)))
    end
    marker = :leak_probe
    let store2 = Store(eng), inst2 = instantiate(store2, CompiledModule(eng, bytes))
        id2 = inst2["ident"]
        for i in 1:200
            id2((marker, i))
        end
        @test table_count(marker) == 200       # alive until the wasm GC runs
        store_gc!(store2)                      # arg+result roots were unrooted
        @test table_count(marker) == 0         # ... so the boxes are released
        # objects held by wasm state survive Julia GC even with no Julia refs
        g2 = inst2["g"]
        g2[] = (marker, -1)
        GC.gc(); GC.gc()
        store_gc!(store2)
        @test g2[] == (marker, -1)
        @test table_count(marker) == 1
        g2[] = nothing
        store_gc!(store2)
        @test table_count(marker) == 0
        # store deletion releases everything that is still registered
        for i in 1:50
            id2((marker, i))
        end
        @test table_count(marker) == 50
        finalize(store2)
        @test table_count(marker) == 0
    end

    # externref global set/get round-trip (and set unroots its temporary)
    g = inst["g"]
    x = Dict(:k => 1)
    g[] = x
    @test g[] === x
    nroots1 = length(store.roots)
    for _ in 1:100
        g[] = x
    end
    @test length(store.roots) == nroots1
end

@testset "read(WasmMemory) returns an owned copy" begin
    eng = Engine()
    m = WasmModule()
    push!(m.mems, MemoryType(Limits(1, 2)))
    push!(m.exports, Export("mem", :memory, 0))
    push!(m.datas, Data(:active, 0, [i32_const(0)], UInt8[0xAA, 0xBB]))
    bytes = encode(m)
    buf = let store = Store(eng)
        inst = instantiate(store, CompiledModule(eng, bytes))
        b = read(inst["mem"])
        finalize(store)   # wasmtime_store_delete unmaps the linear memory
        b
    end
    GC.gc(); GC.gc()
    # with the old unsafe_wrap view this segfaulted (use-after-free)
    @test buf[1] == 0xAA && buf[2] == 0xBB
    @test sum(Int, buf) == Int(0xAA) + Int(0xBB)
    @test length(buf) == 65536
end

@testset "funcref round-trip" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    importfunc!(m, "host", "echo", FuncType([FuncRefT], [FuncRefT]))      # idx 0
    inc_t = FuncType([I64], [I64])
    inc_tidx = addtype!(m, inc_t)
    addfunc!(m, "inc", inc_t, ValType[],
             [local_get(0), i64_const(1), i64_add()]; export_name="inc")  # idx 1
    addfunc!(m, "getf", FuncType(ValType[], [FuncRefT]), ValType[],
             [ref_func(1)]; export_name="getf")                           # idx 2
    addfunc!(m, "mknullf", FuncType(ValType[], [FuncRefT]), ValType[],
             [ref_null(FuncHT)]; export_name="mknullf")
    addfunc!(m, "callf", FuncType([FuncRefT, I64], [I64]), ValType[],
             [i32_const(0), local_get(0), table_set(0),
              local_get(1), i32_const(0), call_indirect(inc_tidx, 0)];
             export_name="callf")
    addfunc!(m, "via_host", FuncType([I64], [I64]), ValType[],
             [i32_const(0), ref_func(1), call(0), table_set(0),
              local_get(0), i32_const(0), call_indirect(inc_tidx, 0)];
             export_name="via_host")
    push!(m.tables, Table(TableType(FuncRefT, Limits(1, 1))))

    lk = Linker(eng)
    define_func!(x -> x, lk, "host", "echo", [:funcref], [:funcref])
    inst = instantiate(lk, store, CompiledModule(eng, encode(m)))

    fr = inst["getf"]()
    @test fr isa WasmFunc                      # wrapped, not a raw CFunc
    @test fr.params == [:i64] && fr.results == [:i64]
    @test fr(41) === Int64(42)                 # callable directly
    @test inst["callf"](fr, 41) === Int64(42)  # and passable back into wasm
    @test inst["mknullf"]() === nothing        # null funcref -> nothing
    # funcref through a host function (host sees a raw CFunc and echoes it)
    @test inst["via_host"](41) === Int64(42)
end

@testset "anyref/exnref results are loud, not silently collapsed" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    # two non-null anyref globals holding *different* i31 values, plus a null one
    push!(m.globals, Global(GlobalType(AnyRefT, true), [i32_const(1), ref_i31()]))
    push!(m.globals, Global(GlobalType(AnyRefT, true), [i32_const(2), ref_i31()]))
    push!(m.globals, Global(GlobalType(AnyRefT, true), [ref_null(AnyHT)]))
    push!(m.exports, Export("g1", :global, 0))
    push!(m.exports, Export("g2", :global, 1))
    push!(m.exports, Export("gnull", :global, 2))
    inst = instantiate(store, CompiledModule(eng, encode(m)))

    # reading a non-null anyref must throw, never return a placeholder that
    # would make two distinct wasm values compare isequal
    @test_throws WasmtimeError inst["g1"][]
    @test_throws WasmtimeError inst["g2"][]
    @test inst["gnull"][] === nothing

    # setting an anyref-typed global is rejected up front (no confusing
    # wasmtime "type mismatch: expected (ref null any), found i64" error,
    # and no silent :i64 fallback)
    @test_throws ArgumentError inst["g1"][] = 5
    @test_throws ArgumentError inst["gnull"][] = nothing
end

# Custom exception whose showerror itself throws: the host-function catch
# block must still produce a clean trap and must not let the secondary
# exception escape the @cfunction (that corrupts wasmtime's trap-handler
# state and aborts the process on the NEXT genuine trap).
struct EvilError <: Exception end
Base.showerror(io::IO, ::EvilError) = error("buggy showerror")

@testset "host exception with broken showerror still traps cleanly" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    importfunc!(m, "host", "bad", FuncType(ValType[], [I64]))
    addfunc!(m, "go", FuncType(ValType[], [I64]), ValType[], [call(0)];
             export_name="go")
    addfunc!(m, "boom", FuncType(ValType[], ValType[]), ValType[],
             [unreachable()]; export_name="boom")
    lk = Linker(eng)
    define_func!(() -> throw(EvilError()), lk, "host", "bad", Symbol[], [:i64])
    inst = instantiate(lk, store, CompiledModule(eng, encode(m)))
    for _ in 1:5
        err = try
            inst["go"]()
            nothing
        catch e
            e
        end
        @test err isa Union{WasmTrap,WasmtimeError}
        @test occursin("showerror itself threw", err.msg)
    end
    # a later genuine trap must still unwind cleanly (no stale trap-handler state)
    @test_throws WasmTrap inst["boom"]()
    @test_throws WasmTrap inst["boom"]()
end

@testset "store lock: same-task wasm->host->wasm re-entrancy" begin
    eng = Engine(); store = Store(eng)
    m = WasmModule()
    importfunc!(m, "host", "reenter", FuncType([I64], [I64]))
    addfunc!(m, "double", FuncType([I64], [I64]), ValType[],
             [local_get(0), i64_const(2), i64_mul()]; export_name="double")
    addfunc!(m, "entry", FuncType([I64], [I64]), ValType[],
             [local_get(0), call(0)]; export_name="entry")
    lk = Linker(eng)
    instref = Ref{Any}(nothing)
    define_func!(lk, "host", "reenter", [:i64], [:i64]) do x
        x <= 0 ? Int64(0) : instref[]["double"](x) + instref[]["entry"](x - 1)
    end
    inst = instantiate(lk, store, CompiledModule(eng, encode(m)))
    instref[] = inst
    @test inst["entry"](3) === Int64(12)   # 2*3 + 2*2 + 2*1 + 0
end

@testset "store lock: concurrent threaded calls on one store are safe" begin
    # Without per-store locking, 8 threads hammering one store's GC-allocating
    # export abort the process (wasmtime DRC collector data race). Run the
    # workload in a subprocess so the regression would fail this test instead
    # of killing the test runner.
    script = joinpath(mktempdir(), "race_threads.jl")
    write(script, """
        using WasmtimeRunner, WasmTools, WasmTools.Instructions
        eng = Engine(); store = Store(eng)
        m = WasmModule()
        boxt = addtype!(m, StructType([FieldType(I64, false)]))
        body = [
            block(), loop(),
                local_get(1), local_get(0), i64_ge_s(), br_if(1),
                local_get(1), struct_new(boxt), struct_get(boxt, 0),
                local_get(2), i64_add(), local_set(2),
                local_get(1), i64_const(1), i64_add(), local_set(1),
                br(0),
            end_(), end_(),
            local_get(2),
        ]
        addfunc!(m, "churn", FuncType([I64], [I64]), ValType[I64, I64], body;
                 export_name="churn")
        inst = instantiate(store, CompiledModule(eng, encode(m)))
        churn = inst["churn"]
        n = Int64(1000); expected = n * (n - 1) ÷ 2
        ok = Threads.Atomic{Int}(0)
        ts = [Threads.@spawn begin
                  good = true
                  for _ in 1:100
                      churn(n) == expected || (good = false)
                  end
                  good && Threads.atomic_add!(ok, 1)
              end for _ in 1:8]
        foreach(wait, ts)
        ok[] == 8 || error("wrong results from \$(8 - ok[]) threads")
        println("THREADTEST OK")
        """)
    cmd = `$(Base.julia_cmd()) -t 8 --project=$(Base.active_project()) $script`
    out = read(ignorestatus(cmd), String)
    @test occursin("THREADTEST OK", out)
end
