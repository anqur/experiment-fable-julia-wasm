# Repro: two+ Julia threads calling WasmFunc objects of the SAME Store concurrently.
# wasmtime's store.h documents "A store generally cannot be concurrently used".
# The WasmtimeRunner wrappers neither document nor enforce this.
#
# Usage: julia -t 8 --project=/workspace race_threads.jl <mode>
#   mode = seq      : sequential control (must pass)
#   mode = perstore : concurrent, one Store per thread (must pass)
#   mode = shared   : concurrent calls on ONE shared Store (the reproduction)

using WasmtimeRunner

const BYTES = read(joinpath(@__DIR__, "churn.wasm"))
const N = Int64(200_000)                 # GC-struct allocations per call
const EXPECTED = N * (N - 1) ÷ 2         # sum 0..N-1
const CALLS_PER_TASK = 25

function mkchurn()
    eng = Engine()
    store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, BYTES))
    return inst["churn"]
end

function run_calls(churn, ncalls)
    bad = 0
    for _ in 1:ncalls
        v = churn(N)
        if v != EXPECTED
            bad += 1
            println(stderr, "WRONG VALUE: got $v expected $EXPECTED")
        end
    end
    return bad
end

mode = isempty(ARGS) ? "shared" : ARGS[1]
nt = Threads.nthreads()
println("mode=$mode threads=$nt")

if mode == "seq"
    churn = mkchurn()
    bad = run_calls(churn, nt * CALLS_PER_TASK)
    println(bad == 0 ? "SEQ OK" : "SEQ BAD=$bad")
    exit(bad == 0 ? 0 : 3)
elseif mode == "perstore"
    bad = Threads.Atomic{Int}(0)
    Threads.@sync for t in 1:nt
        Threads.@spawn begin
            churn = mkchurn()   # private Engine+Store per task
            Threads.atomic_add!(bad, run_calls(churn, CALLS_PER_TASK))
        end
    end
    println(bad[] == 0 ? "PERSTORE OK" : "PERSTORE BAD=$(bad[])")
    exit(bad[] == 0 ? 0 : 3)
elseif mode == "shared"
    churn = mkchurn()           # ONE store shared by all threads
    bad = Threads.Atomic{Int}(0)
    Threads.@sync for t in 1:nt
        Threads.@spawn Threads.atomic_add!(bad, run_calls(churn, CALLS_PER_TASK))
    end
    println(bad[] == 0 ? "SHARED OK (no divergence observed)" : "SHARED BAD=$(bad[])")
    exit(bad[] == 0 ? 0 : 3)
else
    error("unknown mode $mode")
end
