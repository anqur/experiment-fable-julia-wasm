# Probe 2: state corruption after an exception escapes _host_trampoline.
# Vector A: after escape, run a wasm function that traps (unreachable) --
#           wasmtime's longjmp-based trap handling uses TLS CallThreadState;
#           a stale entry from the skipped frame means jumping to a dead frame.
# Vector B: escape from a NESTED wasm->host->wasm->host frame, then keep using
#           the outer machinery.
using WasmtimeRunner
using WasmTools, WasmTools.Instructions

struct EvilError <: Exception end
Base.showerror(io::IO, ::EvilError) = error("showerror is buggy")

eng = Engine(); store = Store(eng)

# --- Vector A ---------------------------------------------------------------
m = WasmModule()
importfunc!(m, "host", "boom", FuncType([I64], [I64]))
addfunc!(m, "go", FuncType([I64], [I64]), ValType[],
         [local_get(0), call(0)]; export_name="go")
addfunc!(m, "trapme", FuncType(ValType[], ValType[]), ValType[],
         [unreachable()]; export_name="trapme")
lk = Linker(eng)
define_func!(lk, "host", "boom", [:i64], [:i64]) do x
    throw(EvilError())
end
inst = instantiate(lk, store, CompiledModule(eng, encode(m)))

for round in 1:3
    r = try inst["go"](1) catch e typeof(e) end
    println("A round $round: escape surfaced as ", r)
end
println("A: now triggering a genuine wasm trap (unreachable)...")
flush(stdout)
t = try inst["trapme"](); :no_trap catch e sprint(showerror, e) end
println("A: trap surfaced as: ", t)
flush(stdout)

# --- Vector B: escape from nested re-entrant frames --------------------------
m2 = WasmModule()
importfunc!(m2, "host", "cb", FuncType([I64], [I64]))
addfunc!(m2, "outer", FuncType([I64], [I64]), ValType[],
         [local_get(0), call(0)]; export_name="outer")
lk2 = Linker(eng)
const OUTER = Ref{Any}(nothing)
define_func!(lk2, "host", "cb", [:i64], [:i64]) do x
    if x > 0
        OUTER[](x - 1)   # re-enter wasm: stack is wasm/host/wasm/host/...
    else
        throw(EvilError())  # escapes through ALL nested wasmtime frames
    end
end
inst2 = instantiate(lk2, store, CompiledModule(eng, encode(m2)))
OUTER[] = inst2["outer"]
r = try inst2["outer"](5) catch e typeof(e) end
println("B: 5-deep nested escape surfaced as ", r)
flush(stdout)
println("B: reusing store after nested escape: outer path with no throw...")
define_ok = try
    # call again but terminate cleanly at depth 0? cb always throws at 0,
    # so instead check a plain trap + a plain call still behave
    t2 = try inst["trapme"](); :no_trap catch e sprint(showerror, e) end
    println("B: trap after nested escape: ", t2)
    v = try inst["go"](1) catch e typeof(e) end
    println("B: go after nested escape: ", v)
    true
catch e
    println("B: store unusable: ", e); false
end
flush(stdout)

# --- Vector C: GC pressure after escapes (skipped Rust destructors) ----------
println("C: forcing GC and exercising store...")
GC.gc(); GC.gc()
for i in 1:50
    try inst2["outer"](3) catch end
end
GC.gc()
println("C: survived 50 nested escapes + GC")
println("PROBE2-COMPLETED-NORMALLY")
