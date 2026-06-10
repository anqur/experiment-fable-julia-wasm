"""
    JSRuntime

Browser-runtime support types for WasmCodegen. Currently: `JSString`, a
JS-native string type lowered to the [js-string builtins]
(https://github.com/WebAssembly/js-string-builtins) — inside wasm a JSString
is an `externref` holding an actual JavaScript string, and its operations
compile to imports from the `"wasm:js-string"` module, which JS engines
provide natively when instantiated with `{builtins: ["js-string"]}`.

Engines without the builtins run the same modules unchanged: the imports are
ordinary imports, bound either to this package's native implementations
(wasmtime, via `offload_imports`) or to a tiny JS polyfill.

Natively a `JSString` wraps its UTF-16 code units, matching JS string
semantics exactly (lone surrogates included) so the usual differential
testing applies.
"""
module JSRuntime

using WasmCodegen
using WasmCodegen: register_externref_type!, register_import_intercept!

export JSString, jslength, charcodeat, codepointat, concat, substring,
       jsequals, fromcharcode, fromcodepoint

"""A JavaScript string: a sequence of UTF-16 code units."""
struct JSString
    units::Vector{UInt16}
end
JSString(s::AbstractString) = JSString(transcode(UInt16, String(s)))
Base.String(s::JSString) = transcode(String, s.units)
Base.:(==)(a::JSString, b::JSString) = a.units == b.units
Base.show(io::IO, s::JSString) = print(io, "js", repr(String(s)))

# The operations below mirror the js-string builtins exactly — including
# trapping behavior (a Julia exception here ≘ a wasm trap there) and the
# unsigned interpretation of i32 index parameters. The bodies are the native
# implementations; in wasm each call lowers to the corresponding
# "wasm:js-string" import (see __init__).

@noinline jslength(s::JSString) = Int32(length(s.units))

@noinline function charcodeat(s::JSString, i::Int32)
    u = reinterpret(UInt32, i)
    u < length(s.units) || throw(BoundsError(s.units, Int64(u) + 1))
    return Int32(@inbounds s.units[u+1])
end

@noinline function codepointat(s::JSString, i::Int32)
    u = Int(reinterpret(UInt32, i))
    u < length(s.units) || throw(BoundsError(s.units, u + 1))
    c1 = @inbounds s.units[u+1]
    if 0xd800 <= c1 <= 0xdbff && u + 1 < length(s.units)
        c2 = @inbounds s.units[u+2]
        if 0xdc00 <= c2 <= 0xdfff
            return Int32(0x10000 + (Int32(c1 - 0xd800) << 10) + Int32(c2 - 0xdc00))
        end
    end
    return Int32(c1)
end

@noinline concat(a::JSString, b::JSString) = JSString(vcat(a.units, b.units))

@noinline function substring(s::JSString, a::Int32, b::Int32)
    len = UInt32(length(s.units))
    ua = min(reinterpret(UInt32, a), len)
    ub = min(reinterpret(UInt32, b), len)
    ua >= ub && return JSString(UInt16[])
    return JSString(s.units[ua+1:ub])
end

@noinline jsequals(a::JSString, b::JSString) = Int32(a.units == b.units)

@noinline fromcharcode(c::Int32) =
    JSString([UInt16(reinterpret(UInt32, c) & 0xffff)])

@noinline function fromcodepoint(c::Int32)
    u = reinterpret(UInt32, c)
    u <= 0x10ffff || throw(DomainError(u, "invalid code point"))
    u < 0x10000 && return JSString([UInt16(u)])
    v = u - 0x00010000
    return JSString([UInt16(0xd800 + (v >> 10)), UInt16(0xdc00 + (v & 0x3ff))])
end

const _BUILTINS = [
    (:jslength, Tuple{JSString}, "length"),
    (:charcodeat, Tuple{JSString,Int32}, "charCodeAt"),
    (:codepointat, Tuple{JSString,Int32}, "codePointAt"),
    (:concat, Tuple{JSString,JSString}, "concat"),
    (:substring, Tuple{JSString,Int32,Int32}, "substring"),
    (:jsequals, Tuple{JSString,JSString}, "equals"),
    (:fromcharcode, Tuple{Int32}, "fromCharCode"),
    (:fromcodepoint, Tuple{Int32}, "fromCodePoint"),
]

function __init__()
    register_externref_type!(JSString)
    for (fname, tt, builtin) in _BUILTINS
        f = getfield(@__MODULE__, fname)
        register_import_intercept!(which(f, tt), "wasm:js-string", builtin, f)
    end
    return nothing
end

end # module JSRuntime
