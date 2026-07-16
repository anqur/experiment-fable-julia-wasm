using NativeCodegen: WasmInterp
import Base.JuliaSyntax as JS

# Statically find every throw_inexacterror call site across the parse! callees,
# so we can identify which checked narrowing conversion traps at runtime for
# 4+-arg calls. We mirror the recursive pipeline's callee discovery minimally:
# specialize parse!(::ParseStream) and walk the inferred call graph via code_ircode.

interp = WasmInterp()

# Collect IRCode for parse! and everything it (transitively) :invoke/:calls.
# We approximate by getting IRCode for the entry and recursing through :invoke
# CodeInstances the same way the compiler does — but a simpler, sufficient pass
# here is to scan IR of a curated set of hot parser functions known to do span
# arithmetic and conversions.
cand_names = [
    :parse!, :parse_stmts, :parse_call_chain, :parse_call,
    :parse_range, :parse_eq, :parse_comparison, :parse_pipe,
    :parse_unary, :parse_atom, :parse_args!, :parse_arglist,
    :parse_assignment_with_initial_ex, :parse_with_chains,
    :emit, :bump_trivia, :bump, :peek, :peek_token,
]
seen = Set{Symbol}()
fns = []
for nm in cand_names
    isdefined(JS, nm) || continue
    f = getfield(JS, nm)
    isa(f, Function) || continue
    key = nameof(f)
    key in seen && continue
    push!(seen, key); push!(fns, f)
end

function scan(f, nargs_hint)
    for argtypes in nargs_hint
        try
            tt = Base.signature_type(f, argtypes)
            ms = Base._methods_by_ftype(tt, -1, interp.world)
            isempty(ms) && continue
            mi = Core.Compiler.specialize_method(ms[1].method, tt, Core.svec())
            r = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
            isempty(r) && continue
            ir, rt = r[1]
            stmts = ir.stmts
            for (i, s) in enumerate(stmts)
                txt = string(s[:stmt])
                if occursin("throw_inexacterror", txt) || occursin("nexacterror", txt)
                    println("\n[", nameof(f), "] stmt ", i, ": ", txt)
                    for j in max(1,i-3):i-1
                        println("    ctx ", j, ": ", stmts[j][:stmt])
                    end
                end
            end
        catch e
        end
    end
end

# Provide a few arity hints per candidate (best-effort)
hints_all = [Tuple{JS.ParseStream}, Tuple{JS.ParseStream, JS.Kind}, Tuple{}]
for f in fns
    scan(f, hints_all)
end
println("\ndone.")
