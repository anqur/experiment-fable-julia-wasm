# Repro: externref ARGUMENT roots are never unrooted after wasmtime_func_call
# (and wasmtime_global_set). Per wasmtime/func.h: "Does not take ownership of
# wasmtime_val_t arguments. Gives ownership of wasmtime_val_t results."
using WasmtimeRunner
using WasmTools, WasmTools.Instructions
import WasmtimeRunner: to_cval, from_cval, _unroot_val, CVal, libwasmtime,
                       check_trap, check_error, WASMTIME_EXTERNREF, CFunc

rss_mb() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1e6

function ident_module()
    m = WasmModule()
    addfunc!(m, "ident", FuncType([ExternRefT], [ExternRefT]), ValType[],
             [local_get(0)]; export_name="ident")
    return encode(m)
end

# replica of (f::WasmFunc)(args...) that unroots externref args after the call
function call_with_arg_unroot(f::WasmFunc, args...)
    ctx = f.store.context
    nargs, nres = length(f.params), length(f.results)
    cargs = CVal[to_cval(ctx, f.store.roots, k, a) for (k, a) in zip(f.params, args)]
    cres = CVal[CVal() for _ in 1:nres]
    trap = Ref{Ptr{Cvoid}}(C_NULL)
    err = ccall((:wasmtime_func_call, libwasmtime), Ptr{Cvoid},
                (Ptr{Cvoid}, Ref{CFunc}, Ptr{CVal}, Csize_t, Ptr{CVal}, Csize_t,
                 Ref{Ptr{Cvoid}}),
                ctx, Ref(f.func), cargs, nargs, cres, nres, trap)
    for v in cargs           # <- the missing unroot discipline
        v.kind == WASMTIME_EXTERNREF && _unroot_val(v)
    end
    check_trap(trap[]); check_error(err)
    return [from_cval(ctx, v; unroot=true) for v in cres]
end

function measure(label, callf; N=300_000)
    eng = Engine(); store = Store(eng)
    inst = instantiate(store, CompiledModule(eng, ident_module()))
    f = inst["ident"]
    for i in 1:1000; callf(f, "warm"); end          # warmup/JIT
    empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
    r0 = rss_mb()
    for i in 1:N
        callf(f, "payload")
        # drop the Julia-side ExternRef boxes so growth isolates wasmtime roots
        i % 5_000 == 0 && empty!(store.roots)
    end
    empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
    r1 = rss_mb()
    println(label, ": RSS delta over $N calls = ", round(r1 - r0; digits=1), " MB")
    return r1 - r0
end

d_plain = measure("as-written  (WasmFunc call)     ", (f, x) -> f(x))
d_fixed = measure("with arg unroot after func_call ", call_with_arg_unroot)
println("ratio plain/fixed = ", round(d_plain / max(d_fixed, 0.1); digits=1))

# --- global set leak ---------------------------------------------------------
function global_module()
    m = WasmModule()
    push!(m.globals, Global(GlobalType(ExternRefT, true), [ref_null(ExternHT)]))
    push!(m.exports, Export("g", :global, 0))
    return encode(m)
end
eng = Engine(); store = Store(eng)
inst = instantiate(store, CompiledModule(eng, global_module()))
g = inst["g"]
g[] = "warm"
empty!(store.roots); GC.gc(); store_gc!(store)
r0 = rss_mb()
for i in 1:200_000
    g[] = "obj"
    i % 5_000 == 0 && empty!(store.roots)
end
empty!(store.roots); GC.gc(); GC.gc(); store_gc!(store)
println("global setindex! RSS delta over 200k sets = ", round(rss_mb() - r0; digits=1), " MB")
