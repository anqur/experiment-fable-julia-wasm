# Probe to understand SyntaxToken and peek_token IR
using NativeCodegen: CC, NCGInterp

const INTERP = NCGInterp()

import Base.JuliaSyntax as JS

# SyntaxToken details
st = JS.SyntaxToken
println("SyntaxToken: $st")
println("  isbitstype: $(isbitstype(st))")
println("  ismutable: $(ismutable(st))")
println("  isprimitivetype: $(isprimitivetype(st))")
println("  sizeof: $(sizeof(st))")
for (i, f) in enumerate(fieldnames(st))
    ft = fieldtype(st, i)
    try
        println("  offset=$(fieldoffset(st, i)): :$f :: $ft (sizeof=$(sizeof(ft)))")
    catch e
        println("  :$f :: $ft")
    end
end

# How does Vector{SyntaxToken} work?
vt = Vector{JS.SyntaxToken}
println("\nVector{SyntaxToken}: $vt")
try
    println("  elsize: $(Base.elsize(vt))")
catch e
    println("  elsize: error: $e")
end

a = JS.SyntaxToken[JS.SyntaxToken(1, 1, 1, 0)]
println("\nCreated vector: $(typeof(a)) with length $(length(a))")
println("  Base.elsize: $(Base.elsize(typeof(a)))")
println("  sizeof element: $(sizeof(eltype(a)))")

# MemoryRef behavior
println("\n\nMemoryRef analysis:")
println("  MemoryRef{SyntaxToken}: sizeof=$(sizeof(Core.MemoryRef{JS.SyntaxToken}))")
println("  The element type for offset computation would be: $(Core.Compiler.typename(Core.MemoryRef{JS.SyntaxToken}).name)")
# Check what fieldoffset gives us for the MemoryRef's .ref field

# What IR does peek_token generate?
f = JS.peek_token
tt = Tuple{typeof(JS.peek_token), JS.ParseStream, Int64}
println("\n\nGetting IR for peek_token($tt)...")

ms = Base._methods_by_ftype(tt, -1, INTERP.world)
if ms !== nothing && !isempty(ms)
    m = ms[1]
    mi = CC.specialize_method(m.method, tt, Core.svec())
    println("MethodInstance: $(mi.def)")
    println("specTypes: $(mi.specTypes)")
    println("  nargs from def: $(mi.def.nargs)")

    code_infos = Base.code_ircode_by_type(mi.specTypes; world=INTERP.world, interp=INTERP)
    ir, ret = code_infos[1]
    println("\n--- IR for peek_token(ParseStream, Int64) ---")
    println("argtypes: $(ir.argtypes)")
    println("nargs: $(length(ir.argtypes))")
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
    println("No method found")
end
