# CLIF type mapping and emitter state.
# Split from clif_emit.jl to stay within Julia flisp parser stack limits.

# === CLIF type mapping ===

const CLIF_TYPE = IdDict{Any,String}(
    Int64   => "i64",
    UInt64  => "i64",
    Int32   => "i32",
    UInt32  => "i32",
    Int16   => "i32",
    UInt16  => "i32",
    Int8    => "i32",
    UInt8   => "i32",
    Bool    => "i32",
    Char    => "i32",
    Float64 => "f64",
    Float32 => "f32",
)

"""Get the CLIF type string for a Julia type."""
function clif_type(T)
    t = get(CLIF_TYPE, T, nothing)
    t !== nothing && return t
    r = scalar_repr(T)
    r === nothing && throw(CompileError("unsupported CLIF type $T"))
    return clif_type_string(r)
end

clif_type_string(r::ScalarRepr) = r.vt == WasmTools.I64 ? "i64" :
    r.vt == WasmTools.I32 ? "i32" :
    r.vt == WasmTools.F64 ? "f64" : "f32"

# === CLIF emitter state ===

mutable struct CLIFContext
    io::IOBuffer
    indent::Int
    next_value::Int
    next_block::Int
    next_jt::Int
end

CLIFContext() = CLIFContext(IOBuffer(), 0, 0, 0, 0)

function emit(ctx::CLIFContext, s::String)
    write(ctx.io, repeat("    ", ctx.indent))
    write(ctx.io, s)
    write(ctx.io, '\n')
    return nothing
end

function emit_raw(ctx::CLIFContext, s::String)
    write(ctx.io, s)
    return nothing
end

"""Get a fresh SSA value name."""
fresh_value(ctx::CLIFContext) = (v = ctx.next_value; ctx.next_value += 1; "v$v")

"""Get a fresh block name."""
fresh_block(ctx::CLIFContext) = (b = ctx.next_block; ctx.next_block += 1; "block$b")

"""Get a fresh jump table name."""
fresh_jt(ctx::CLIFContext) = (j = ctx.next_jt; ctx.next_jt += 1; "jt$j")
