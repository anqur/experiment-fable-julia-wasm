# Custom AbstractInterpreter for native codegen.
# Directly reuses WasmCodegen's WasmInterp — the overlay method table and
# stubs are pure Julia and fully target-agnostic. The overlay replaces
# pointer-based Base primitives (memcpy, memchr, utf8proc) with loop-based
# equivalents before inlining, making them compilable to any target.
#
# The interception registry, on the other hand, IS target-specific:
# WasmCodegen wires certain overlay methods to custom wasm instruction
# sequences; NativeCodegen either provides CLIF equivalents or falls
# back to host calls.

using WasmCodegen: WasmInterp
# InterceptSpec is defined in WasmCodegen's interp.jl, not exported but accessible
const InterceptSpec = WasmCodegen.InterceptSpec

# Native-specific interception registry.
# Phase 1 (scalar-only): everything falls back to hostcall or compiles naturally.
const NATIVE_INTERCEPTS = IdDict{Method,InterceptSpec}()

function _register_native_intercepts!()
    empty!(NATIVE_INTERCEPTS)
    # Phase 1: no custom intercepts yet — string ops, copyto, etc. compile
    # as regular Julia code (the overlay bodies are simple loops).
    # Phase 2+: register CLIF-specific emission functions for codeunit,
    # ncodeunits, unsafe_copyto!, etc.
    return nothing
end
