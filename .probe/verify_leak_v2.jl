# Independent verification: externref arg roots leaked by (f::WasmFunc)(args...)
# and Base.setindex!(::WasmGlobal, x). wasmtime docs: func_call/global_set do NOT
# take ownership of wasmtime_val_t args; externref_new roots MUST be unrooted.
using WasmtimeRunner
using WasmTools, WasmTools.Instructions
import WasmtimeRunner: to_cval, from_cval, _unroot_val, CVal, CFunc, libwasmtime,
                       check_trap, check_error, WASMTIME_EXTERNREF, WASMTIME_ANYREF,
                       WASMTIME_EXNREF

rss_mb() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1e6

function ident_module()
    m = WasmModule()
    addfunc!(m, "ident", FuncType([ExternRefT], [ExternRefT]), ValType[],
             [local_get(0)]; export_name="ident")
    return encode(m)
end

# Fixed variant of the call path: identical except args are unrooted after the call.
function call_fixed(f::WasmFunc, args...)
    ctx = f.store.context
    nargs, nres = length(f.params), length(f.results)
    cargs = CVal[to_cval(ctx, f.store.roots, k, a) for (k, a) in zip(f.params, args)]
    cres = CVal[CVal() for _ in 1:nres]
    trap = Ref{Ptr{Cvoid}}(C_NULL)
    err = ccall((:wasmtime_func_call, libwasmtime), Ptr{Cvoid},
                (Ptr{Cvoid}, Ref{CFunc}, Ptr{CVal}, Csize_t, Ptr{CVal}, Csize_t,
                 Ref{Ptr{Cvoid}}),
                ctx, Ref(f.func), cargs, nargs, cres, nres, trap)
    for v in cargs
        v.kind in (WASMTIME_EXTERNREF, WASMTIME_ANYREF, WASMTIME_EXNREF) && _unroot_val(v)
    end
    check_trap(trap[]); check_error(err)
    vals = [from_cval(ctx, v; unroot=true) for v in cres]
    return vals[1]
end

function measure_calls(label, callf; N=300_000)
    eng = Engine(); store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, ident_module()))
    f = inst["ident"]
    obj = "payload"
    @assert callf(f, obj) === obj   # semantic sanity: identity round-trip works
    for _ in 1:2000; callf(f, obj); end
    empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
    r0 = rss_mb()
    for i in 1:N
        callf(f, obj)
        i % 4096 == 0 && empty!(store.roots)  # isolate the wasmtime-side root slab
    end
    nroots_unbounded = length(store.roots)    # Julia-side: grows per call between empties
    empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
    d = rss_mb() - r0
    println(label, ": RSS delta = ", round(d; digits=1), " MB over $N calls",
            "  (roots vec had ", nroots_unbounded, " entries pending at loop end)")
    return d
end

d_asis  = measure_calls("AS-WRITTEN f(x)        ", (f, x) -> f(x))
d_fixed = measure_calls("FIXED (unroot args)    ", call_fixed)

# Julia-side roots vector growth (never trimmed by the package itself)
let eng = Engine(), store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, ident_module()))
    f = inst["ident"]
    n0 = length(store.roots)
    for _ in 1:10_000; f("x"); end
    println("store.roots growth over 10k calls (as written): ", length(store.roots) - n0)
end

# --- global set ---------------------------------------------------------------
function global_module()
    m = WasmModule()
    push!(m.globals, Global(GlobalType(ExternRefT, true), [ref_null(ExternHT)]))
    push!(m.exports, Export("g", :global, 0))
    return encode(m)
end
let eng = Engine(), store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, global_module()))
    g = inst["g"]
    g[] = "warm"
    @assert g[] == "warm"   # semantic sanity
    empty!(store.roots); GC.gc(); store_gc!(store)
    r0 = rss_mb()
    for i in 1:200_000
        g[] = "obj"
        i % 4096 == 0 && empty!(store.roots)
    end
    empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
    println("global setindex! RSS delta = ", round(rss_mb() - r0; digits=1),
            " MB over 200k sets")
end

println("VERDICT: leak ", d_asis > 10 && d_fixed < 2 ? "CONFIRMED" : "NOT confirmed",
        " (as-written ", round(d_asis; digits=1), " MB vs fixed ",
        round(d_fixed; digits=1), " MB)")
