# Repro 2 (single OS thread): a host function that yields suspends its Task
# mid-wasm-call; another Task then enters the SAME store, producing interleaved
# store use that wasmtime's &mut contract forbids. Exits are forced non-LIFO.
#
# Usage: julia -t 1 --project=/workspace race_tasks.jl

using WasmtimeRunner

const BYTES = read(joinpath(@__DIR__, "pause.wasm"))
const N = Int64(200_000)
const EXPECTED = N * (N - 1) ÷ 2

eng = Engine()
store = Store(eng)
lk = Linker(eng)

gates = [Channel{Nothing}(1), Channel{Nothing}(1)]
define_func!(lk, "host", "pause", [:i64], Symbol[]) do id
    take!(gates[Int(id)])   # blocks => yields this Task inside the wasm call
    nothing
end

inst = instantiate(lk, store, CompiledModule(eng, BYTES))
go = inst["go"]
trapme = inst["trapme"]

results = Dict{Int,Any}()
t1 = @async (results[1] = try go(1, N) catch e; e end)
t2 = @async (results[2] = try go(2, N) catch e; e end)
yield(); yield()   # both tasks are now suspended inside wasm->host->take!
println("both tasks suspended inside the same store: ",
        istaskstarted(t1) && !istaskdone(t1) && istaskstarted(t2) && !istaskdone(t2))

# Release task 1 FIRST (it entered the store first) => its wasm call exits while
# task 2's activation is still live: non-LIFO interleaving of store use.
put!(gates[1], nothing); wait(t1)
put!(gates[2], nothing); wait(t2)

ok = true
for id in 1:2
    r = results[id]
    if r != EXPECTED
        global ok = false
        println("task $id WRONG/ERR: ", r)
    end
end

# After interleaved exits, is trap handling still sane on this store?
trap_ok = try
    trapme(1)
    println("trapme: NO TRAP (wrong: should be divide-by-zero)")
    false
catch e
    msg = sprint(showerror, e)
    occursin("divide by zero", msg) || println("trapme: unexpected error: ", msg)
    occursin("divide by zero", msg)
end

# And do plain calls still produce correct values?
put!(gates[1], nothing)   # pre-fill so the host pause does not block
post = try go(1, N) catch e; e end
post == EXPECTED || (global ok = false; println("post-interleave call WRONG: ", post))

if ok && trap_ok
    println("TASK-INTERLEAVE: no divergence observed in this run")
    exit(0)
else
    println("TASK-INTERLEAVE: DIVERGENCE")
    exit(3)
end
