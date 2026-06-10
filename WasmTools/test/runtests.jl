using Test
using WasmTools
using WasmTools.Instructions
const WT = WasmTools

# Locate the external wasm-tools binary for validation (optional but strongly
# recommended; tests that need it are skipped when unavailable).
function find_wasm_tools()
    candidates = [
        get(ENV, "WASM_TOOLS", ""),
        "/workspace/tools/wasm-tools-dist/wasm-tools",
        something(Sys.which("wasm-tools"), ""),
    ]
    for c in candidates
        !isempty(c) && isfile(c) && return c
    end
    return nothing
end
const WASM_TOOLS = find_wasm_tools()

function wt_validate(bytes::Vector{UInt8})
    WASM_TOOLS === nothing && return true, "skipped"
    mktemp() do path, io
        write(io, bytes); close(io)
        err = IOBuffer()
        ok = success(pipeline(`$WASM_TOOLS validate --features all $path`; stderr=err))
        return ok, String(take!(err))
    end
end

function wt_parse(wat::String)
    mktemp() do path, io
        write(io, wat); close(io)
        return read(`$WASM_TOOLS parse $path`)
    end
end

"Assert byte-stable round trip: encode → decode → encode is the identity."
function roundtrip(m::WasmModule)
    bytes = encode(m)
    m2 = decode(bytes)
    bytes2 = encode(m2)
    @test bytes2 == bytes
    ok, err = wt_validate(bytes)
    ok || println(stderr, "wasm-tools validation failed:\n", err, "\n", wat(m))
    @test ok
    return m2
end

@testset "LEB128" begin
    for x in [0, 1, 63, 64, 127, 128, 300, 624485, typemax(UInt32), UInt64(typemax(UInt64))]
        io = IOBuffer()
        WT.write_uleb(io, x)
        seekstart(io)
        @test WT.read_uleb(io) == UInt64(x)
    end
    for x in [0, 1, -1, 63, -64, 64, -65, 127, 128, -123456, typemax(Int64), typemin(Int64),
              Int64(typemax(Int32)), Int64(typemin(Int32))]
        io = IOBuffer()
        WT.write_sleb(io, x)
        seekstart(io)
        @test WT.read_sleb(io) == Int64(x)
    end
    # canonical encodings from the spec
    io = IOBuffer(); WT.write_uleb(io, 624485)
    @test take!(io) == UInt8[0xE5, 0x8E, 0x26]
    io = IOBuffer(); WT.write_sleb(io, -123456)
    @test take!(io) == UInt8[0xC0, 0xBB, 0x78]
end

@testset "golden add module" begin
    m = WasmModule()
    addfunc!(m, nothing, FuncType([I64, I64], [I64]), ValType[],
             [local_get(0), local_get(1), i64_add()]; export_name="add")
    bytes = encode(m)
    golden = UInt8[
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7E, 0x7E, 0x01, 0x7E,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
        0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x7C, 0x0B,
    ]
    @test bytes == golden
    m2 = roundtrip(m)
    @test length(m2.funcs) == 1
    @test m2.funcs[1].body == [local_get(0), local_get(1), i64_add()]
    @test getfunctype(m2, m2.funcs[1].typeidx) == FuncType([I64, I64], [I64])
    @test m2.exports == [Export("add", :func, 0)]
end

@testset "control flow + numerics" begin
    m = WasmModule()
    # gcd(a, b) via Euclid: loop with branches
    body = [
        block(nothing),
        loop(nothing),
        local_get(1),
        i64_eqz(),
        br_if(1),
        local_get(1),                 # t = b
        local_get(0),
        local_get(1),
        i64_rem_s(),                  # a % b
        local_set(1),
        local_set(0),
        br(0),
        end_(),
        end_(),
        local_get(0),
    ]
    addfunc!(m, "gcd", FuncType([I64, I64], [I64]), ValType[], body; export_name="gcd")
    # float kitchen sink incl. NaN constant
    fbody = [
        f64_const(1.5), f64_const(NaN), f64_add(),
        f64_const(-Inf), f64_min(),
        local_get(0), f64_sqrt(), f64_max(),
    ]
    addfunc!(m, "fsink", FuncType([F64], [F64]), ValType[], fbody; export_name="fsink")
    # if/else, select, br_table, conversions, locals
    sbody = [
        local_get(0),
        i32_wrap_i64(),
        if_(I64),
        local_get(0), i64_const(2), i64_mul(),
        else_(),
        local_get(0), i64_const(-7), i64_add(),
        end_(),
        local_set(1),
        block(nothing),
        block(nothing),
        block(nothing),
        local_get(1), i32_wrap_i64(), i32_const(3), i32_rem_u(),
        br_table([0, 1], 2),
        end_(),
        local_get(1), i64_const(100), i64_add(), local_set(1), br(1),
        end_(),
        local_get(1), i64_popcnt(), local_set(1),
        end_(),
        local_get(1),
        local_get(0),
        local_get(0), i64_const(0), i64_lt_s(),
        select(),
    ]
    addfunc!(m, "sel", FuncType([I64], [I64]), ValType[I64], sbody; export_name="sel")
    m2 = roundtrip(m)
    @test m2.funcs[1].name == "gcd"
    @test m2.funcs[2].body[2] == f64_const(NaN)
end

@testset "GC types and instructions" begin
    m = WasmModule()
    # rec group: mutually recursive struct types, with subtyping
    base = SubType(false, UInt32[], StructType([FieldType(I64, false)]))
    node = SubType(true, UInt32[0],
        StructType([FieldType(I64, false),
                    FieldType(RefType(true, HeapType(1)), true),
                    FieldType(I8, true)]))
    addtype!(m, RecGroup([base, node]))
    arr = addtype!(m, ArrayType(FieldType(F64, true)))           # 2
    addtype!(m, ArrayType(FieldType(I16, true)))                 # 3
    ft = addtype!(m, FuncType([typeref(1; nullable=true)], [I64]))  # 4

    body = [
        local_get(0),
        ref_cast_null(HeapType(1)),
        struct_get(1, 0),               # node.i64 field
        local_get(0),
        ref_test(StructHT),
        i64_extend_i32_u(),
        i64_add(),
        # build an array, read element, convert, add
        f64_const(0.5),
        i32_const(3),
        array_new(arr),
        i32_const(1),
        array_get(arr),
        i64_trunc_sat_f64_s(),
        i64_add(),
        # i31 round trip
        i32_const(42),
        ref_i31(),
        i31_get_s(),
        i64_extend_i32_s(),
        i64_add(),
    ]
    addfunc!(m, "gcfun", FuncType([typeref(1; nullable=true)], [I64]), ValType[], body;
             export_name="gcfun")

    # struct construction + null + eq
    body2 = [
        i64_const(7),
        struct_new(0),
        ref_null(HeapType(1)),
        ref_is_null(),
        drop(),
        struct_get(0, 0),
    ]
    addfunc!(m, "mk", FuncType(ValType[], [I64]), ValType[], body2; export_name="mk")

    # globals with GC init, declarative elem + ref.func, call_ref
    push!(m.globals, Global(GlobalType(RefType(true, AnyHT), true),
                            [i32_const(5), ref_i31()]))
    push!(m.elems, Elem(:declarative, FuncRefT, [[ref_func(0)]]))
    body3 = [
        local_get(0),
        ref_func(0),
        call_ref(ft),
    ]
    addfunc!(m, "callref", FuncType([typeref(1; nullable=true)], [I64]), ValType[], body3;
             export_name="callref")
    roundtrip(m)
end

@testset "imports, tables, memory, data, tags" begin
    m = WasmModule()
    tag_ft = addtype!(m, FuncType([I64], ValType[]))
    importfunc!(m, "host", "f", FuncType([I64], [I64]))
    push!(m.imports, Import("host", "g", GlobalType(I64, false)))
    push!(m.imports, Import("host", "mem", MemoryType(Limits(1, 10))))
    push!(m.imports, Import("host", "tab", TableType(FuncRefT, Limits(0, nothing))))
    push!(m.tags, TagType(tag_ft))

    push!(m.tables, Table(TableType(FuncRefT, Limits(4, 4))))
    push!(m.mems, MemoryType(Limits(1, nothing)))
    push!(m.globals, Global(GlobalType(I64, true), [i64_const(0)]))
    push!(m.datas, Data(:active, 1, [i32_const(0)], UInt8[1, 2, 3, 4]))
    push!(m.datas, Data(UInt8[5, 6]))

    body = [
        local_get(0),
        call(0),
        i32_const(0),
        i64_load(MemArg(align=3, offset=8)),
        i64_add(),
        i32_const(0), i32_const(0), i32_const(2),
        memory_init(1, 0),
        i32_const(8), local_get(0), i64_store(MemArg()),
        memory_size(0), drop(),
        global_get(0), i64_add(),
        global_get(1), i64_add(),
    ]
    f = addfunc!(m, "main", FuncType([I64], [I64]), ValType[], body; export_name="main")
    push!(m.elems, Elem(:active, 1, [i32_const(0)], FuncRefT, [[ref_func(0)], [ref_func(f)]]))
    push!(m.exports, Export("mem0", :memory, 0))
    push!(m.customs, CustomSection("producers", UInt8[0x00]))
    roundtrip(m)
end

@testset "exceptions" begin
    m = WasmModule()
    et = addtype!(m, FuncType([I64], ValType[]))
    push!(m.tags, TagType(et))
    # catch branches (with the thrown i64 payload) to the enclosing block
    body = [
        block(I64),
        try_table(nothing, [Catch(0x00, 0, 0)]),   # catch tag 0 -> label 0
        local_get(0),
        i64_eqz(),
        if_(),
        local_get(0), throw_(0),
        end_(),
        end_(),
        i64_const(1),
        return_(),
        end_(),
        i64_const(100),
        i64_add(),
    ]
    addfunc!(m, "exn", FuncType([I64], [I64]), ValType[], body; export_name="exn")
    roundtrip(m)
end

@testset "decode external binaries" begin
    if WASM_TOOLS === nothing
        @test_skip "wasm-tools not available"
    else
        watsrc = """
        (module
          (rec
            (type \$a (sub (struct (field i64))))
            (type \$b (sub \$a (struct (field i64) (field (mut (ref null \$b)))))))
          (type \$arr (array (mut i8)))
          (func \$grow (param (ref null \$a)) (result i64)
            local.get 0
            (ref.test (ref \$b))
            if (result i64)
              local.get 0
              ref.cast (ref \$b)
              struct.get \$b 0
            else
              i64.const -1
            end)
          (func \$mkarr (result i32)
            i32.const 65
            i32.const 10
            array.new \$arr
            array.len)
          (export "grow" (func \$grow))
          (export "mkarr" (func \$mkarr)))
        """
        bytes = wt_parse(watsrc)
        m = decode(bytes)
        @test length(m.funcs) == 2
        @test numtypes(m) == 5   # rec(a, b), arr, and one functype per function
        bytes2 = encode(m)
        ok, err = wt_validate(bytes2)
        ok || println(stderr, err)
        @test ok
        # our re-encoding decodes to the same structure
        m2 = decode(bytes2)
        @test encode(m2) == bytes2
        @test m2.funcs[1].body == m.funcs[1].body
        @test flattypes(m2) == flattypes(m)
    end
end

@testset "wat printer smoke test" begin
    m = WasmModule()
    addfunc!(m, "add", FuncType([I64, I64], [I64]), ValType[],
             [local_get(0), local_get(1), i64_add()]; export_name="add")
    s = wat(m)
    @test occursin("i64.add", s)
    @test occursin("(export \"add\"", s)
end

@testset "malformed input" begin
    @test_throws WT.MalformedError decode(UInt8[0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00])
    @test_throws Exception decode(UInt8[0x00, 0x61])
    m = WasmModule()
    addfunc!(m, nothing, FuncType([I64], [I64]), ValType[], [local_get(0)])
    bytes = encode(m)
    @test_throws Exception decode(bytes[1:end-3])
end
