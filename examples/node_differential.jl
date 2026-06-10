# Differential test of WasmCodegen output across THREE engines:
# native Julia, wasmtime (via WasmtimeRunner), and V8 (via Node.js) — the
# browser execution path.
#
# Run: julia --project=/workspace examples/node_differential.jl

using WasmCodegen
using WasmtimeRunner

mygcd(a::Int64, b::Int64) = b == 0 ? (a < 0 ? -a : a) : mygcd(b, a % b)
fib(n::Int64) = n <= 1 ? n : fib(n - 1) + fib(n - 2)

mutable struct Node_
    val::Int64
    next::Union{Nothing,Node_}
end
function buildsum(n::Int64)
    head = nothing
    for i in 1:n
        head = Node_(i, head)
    end
    s = 0
    cur = head
    while cur !== nothing
        s += cur.val
        cur = cur.next
    end
    return s
end

horner(x::Float64) = @evalpoly(x, 1.0, -2.0, 3.0, -4.0)

const NODE = something(Sys.which("node"), "node")
const RUNNER = joinpath(@__DIR__, "run_wasm.mjs")

function run_node(comp::WasmCompilation, args...)
    path = tempname() * ".wasm"
    write(path, comp.bytes)
    jsargs = [x isa AbstractFloat ? string(Float64(x)) : string(x) for x in args]
    out = try
        readchomp(`$NODE $RUNNER $path $(comp.entry) $jsargs`)
    catch
        "trap"
    end
    rm(path; force=true)
    return out
end

function run_wasmtime(comp::WasmCompilation, args...)
    eng = Engine()
    store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, comp.bytes))
    return inst[comp.entry](args...)
end

fails = 0
for (f, argtypes, cases) in [
    (mygcd, Tuple{Int64,Int64}, [(12, 18), (17, 5), (-12, 18), (0, 0)]),
    (fib, Tuple{Int64}, [(10,), (20,)]),
    (buildsum, Tuple{Int64}, [(0,), (100,)]),
    (horner, Tuple{Float64}, [(1.5,), (-2.0,)]),
]
    comp = compile_wasm(f, argtypes)
    isempty(comp.offloads) || error("demo functions must not need offloads")
    for args in cases
        native = f(args...)
        wt = run_wasmtime(comp, args...)
        v8raw = run_node(comp, args...)
        v8 = try
            parse(typeof(native), v8raw)
        catch
            v8raw
        end
        agree = isequal(native, v8) && isequal(native, wt)
        agree || (global fails += 1)
        status = agree ? "ok " : "FAIL"
        println("[$status] $(comp.entry)$(args): native=$native wasmtime=$wt v8=$v8")
    end
end
println(fails == 0 ? "\nAll engines agree." : "\n$fails disagreements!")
exit(fails == 0 ? 0 : 1)
