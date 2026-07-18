# Probe to get Julia IR of Base.JuliaSyntax.peek_token
using NativeCodegen: CC, NCGInterp
import Base.JuliaSyntax as JS

const INTERP = NCGInterp()

# First, let's get the ParseStream type
ps_type = JS.ParseStream
println("ParseStream = $ps_type")
println("ParseStream fields:")
for (i, f) in enumerate(fieldnames(ps_type))
    ft = fieldtype(ps_type, i)
    sz_str = try string(sizeof(ft)) catch e "?" end
    off_str = try string(fieldoffset(ps_type, i)) catch e "?" end
    println("  offset=$off_str: :$f :: $ft (sizeof=$sz_str)")
end

# peek_token method
f = JS.peek_token
println("\npeek_token methods:")
for m in methods(f)
    println("  $m")
end

# Get the specific method for (ParseStream, Int64)
tt = Tuple{typeof(JS.peek_token), JS.ParseStream, Int64}
println("\nTrying signature type: $tt")
try
    ms = Base._methods_by_ftype(tt, -1, INTERP.world)
    if ms !== nothing && !isempty(ms)
        m = ms[1]
        mi = CC.specialize_method(m.method, tt, Core.svec())
        println("MethodInstance: $(mi.def)")
        println("specTypes: $(mi.specTypes)")

        ir, ret = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)[1]
        println("\n--- IR for peek_token(ParseStream, Int64) ---")
        println("argcount = $(ir.argcount)")
        for (i, arg) in enumerate(ir.argtypes)
            println("  arg $i: $arg")
        end
        println("Blocks: $(length(ir.cfg.blocks))")
        for (bi, block) in enumerate(ir.cfg.blocks)
            println("Block $bi: $(length(block.stmts)) stmts, preds=$(block.preds), succs=$(block.succs)")
        end
        for (si, stmt) in enumerate(ir.stmts)
            println("stmt[$si]: $(stmt)")
        end
        println("\n--- return type: $ret ---")
    else
        println("No method found for $tt")
    end
catch e
    println("Error: $e")
    bt = catch_backtrace()
    showerror(stdout, e, bt)
end

# Also try with just ParseStream (no pos)
tt2 = Tuple{typeof(JS.peek_token), JS.ParseStream}
println("\n\nTrying signature type: $tt2")
try
    ms2 = Base._methods_by_ftype(tt2, -1, INTERP.world)
    if ms2 !== nothing && !isempty(ms2)
        m2 = ms2[1]
        mi2 = CC.specialize_method(m2.method, tt2, Core.svec())
        println("MethodInstance: $(mi2.def)")
        println("specTypes: $(mi2.specTypes)")

        ir2, ret2 = Base.code_ircode_by_type(mi2.specTypes; world=INTERP.world, interp=INTERP)[1]
        println("\n--- IR for peek_token(ParseStream) ---")
        println("argcount = $(ir2.argcount)")
        for (i, arg) in enumerate(ir2.argtypes)
            println("  arg $i: $arg")
        end
        for (si, stmt) in enumerate(ir2.stmts)
            println("stmt[$si]: $(stmt)")
        end
        println("\n--- return type: $ret2 ---")
    else
        println("No method found for $tt2")
    end
catch e
    println("Error: $e")
end

# The Lexer method
println("\n\n--- Peeking at Lexer fields ---")
for (i, f) in enumerate(fieldnames(JS.Lexer))
    ft = fieldtype(JS.Lexer, i)
    off_str = try string(fieldoffset(JS.Lexer, i)) catch e "?" end
    sz_str = try string(sizeof(ft)) catch e "?" end
    println("  offset=$off_str: :$f :: $ft (sizeof=$sz_str)")
end

# What does peek_token return?
ret_type = Base.return_types(JS.peek_token, Tuple{JS.ParseStream, Int64})[1]
println("\npeek_token(ParseStream, Int64) return type: $ret_type")

# peek_token core method
println("\n\n--- Core method (non-kw) for peek_token ---")
for (mm, _) in Base._methods(JS.peek_token, Tuple{JS.ParseStream, Int64}, -1, INTERP.world)
    println("  method: $(mm)")
    println("  name: $(mm.name)")
end

# Let's also look at __peek_token__ (the core method without kwargs)
try
    peek_core = JS.peek_token
    # The kw sorter creates a synthetic method. Let's try getting the non-kw method
    ms3 = Base._methods_by_ftype(tt, -1, INTERP.world)
    if ms3 !== nothing && !isempty(ms3)
        m3 = ms3[1]
        println("\npeek_token core method: $(m3.method)")
        println("  is kw sorter: $(isdefined(m3.method, :is_kw_sorter) ? m3.method.is_kw_sorter : "?")")
    end
catch e
    println("Error: $e")
end
