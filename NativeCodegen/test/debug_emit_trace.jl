using NativeCodegen
using NativeCodegen: WasmInterp, BuilderCtx, emit_instruction, emit_call_runtime

# Monkey-patch emit_instruction to trace memoryrefnew and memoryrefget
const ORIG_EMIT_INSTRUCTION = emit_instruction

function traced_emit_instruction(bc::BuilderCtx, e, ir, stmt_idx::Int)
    if e isa Expr && e.head == :call
        f = e.args[1]
        if f === Core.memoryrefnew || (f isa Core.GlobalRef && f.name == :memoryrefnew)
            println("  [trace] stmt $stmt_idx: memoryrefnew args=$(e.args)")
        elseif f === Core.memoryrefget || (f isa Core.GlobalRef && f.name == :memoryrefget)
            println("  [trace] stmt $stmt_idx: memoryrefget args=$(e.args)")
        end
    end
    ORIG_EMIT_INSTRUCTION(bc, e, ir, stmt_idx)
end

# Replace the function
@eval NativeCodegen emit_instruction = $traced_emit_instruction

using NativeCodegen: compile_and_call

function pop_resize_only(a::Vector{Int64})
    n = length(a)
    @inbounds v = a[n]
    resize!(a, n-1)
    v
end

println("=== Traced compilation ===")
a = Int64[10,20,30]
try
    r = compile_and_call(pop_resize_only, Int64, Tuple{Vector{Int64}}, a)
    println("Result: $r (expected 30)")
    println("Array after: $a")
catch e
    println("Error: ", e)
end
