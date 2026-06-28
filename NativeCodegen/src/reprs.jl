# Mapping from Julia types to native value representations.
# Reuses WasmCodegen's target-agnostic ScalarRepr system.
#
# Scalars are stored in i64/i32/f64/f32. Sub-word integers (Int8/16, UInt8/16)
# live in i32 with a normalization discipline: signed values sign-extended,
# unsigned values zero-extended; arithmetic renormalizes.
#
# Char is stored as its RAW 32-bit pattern (UTF-8 bytes left-justified) — the
# exact same representation native Julia uses.

# Re-export everything from WasmCodegen (target-agnostic)
using WasmCodegen: ScalarRepr, _SCALAR_REPRS, scalar_repr, isghost, ghost_instance,
    wasm_valtype, valkind_sym, from_wire, to_wire

# For native code, we use the same value type mapping as wasm:
# i32 → i32, i64 → i64, f32 → f32, f64 → f64
# CLIF uses the same type names as wasm for scalars.
