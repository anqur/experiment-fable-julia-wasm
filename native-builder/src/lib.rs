// Native Builder: eDSL API for Julia → Native compilation
// Direct Cranelift IR emission via transient FunctionBuilder

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::sync::Mutex;

mod builder;
mod linker;
mod runtime;

use builder::{BuilderContext, FunctionCtx, map_icmp_cond, map_fcmp_cond, TYPE_I64};

// Thread-safe builder registry
struct Bp(*mut BuilderContext); unsafe impl Send for Bp {}
static BUILDERS: Mutex<Vec<Bp>> = Mutex::new(Vec::new());

#[no_mangle]
pub extern "C" fn create_builder() -> *mut BuilderContext {
    let ctx = Box::new(BuilderContext::new());
    let ptr = Box::into_raw(ctx);
    if let Ok(mut b) = BUILDERS.lock() { b.push(Bp(ptr)); }
    ptr
}

#[no_mangle]
pub extern "C" fn free_builder(ctx: *mut BuilderContext) {
    if ctx.is_null() { return; }
    if let Ok(mut b) = BUILDERS.lock() { b.retain(|bp| bp.0 != ctx); }
    unsafe { let _ = Box::from_raw(ctx); }
}

#[no_mangle]
pub extern "C" fn builder_add_function(
    ctx: *mut BuilderContext, name: *const c_char,
    ret_type: u32, param_types: *const u32, num_params: usize,
) -> *mut FunctionCtx {
    if ctx.is_null() || name.is_null() || (num_params > 0 && param_types.is_null()) {
        return std::ptr::null_mut();
    }
    unsafe {
        let nm = CStr::from_ptr(name).to_str().unwrap_or("fn");
        let types = std::slice::from_raw_parts(param_types, num_params);
        (*ctx).add_function(nm, ret_type, types).unwrap_or(std::ptr::null_mut())
    }
}

#[no_mangle]
pub extern "C" fn builder_declare_import(
    ctx: *mut BuilderContext, name: *const c_char,
    ret_type: u32, param_types: *const u32, num_params: usize,
) -> c_int {
    if ctx.is_null() || name.is_null() || (num_params > 0 && param_types.is_null()) {
        return -1;
    }
    unsafe {
        let nm = CStr::from_ptr(name).to_str().unwrap_or("import");
        let types = std::slice::from_raw_parts(param_types, num_params);
        match (*ctx).declare_import(nm, ret_type, types) {
            Ok(()) => 0,
            Err(e) => { eprintln!("[native-builder] {}", e); -1 }
        }
    }
}

#[no_mangle]
pub extern "C" fn builder_declare_self_function(
    ctx: *mut BuilderContext, name: *const c_char,
    ret_type: u32, param_types: *const u32, num_params: usize,
) -> c_int {
    if ctx.is_null() || name.is_null() || (num_params > 0 && param_types.is_null()) {
        return -1;
    }
    unsafe {
        let nm = CStr::from_ptr(name).to_str().unwrap_or("self_func");
        let types = std::slice::from_raw_parts(param_types, num_params);
        match (*ctx).declare_self_function(nm, ret_type, types) {
            Ok(()) => 0,
            Err(e) => { eprintln!("[native-builder] {}", e); -1 }
        }
    }
}

#[no_mangle]
pub extern "C" fn block_add_call(
    fctx: *mut FunctionCtx, ctx: *mut BuilderContext,
    name: *const c_char, args: *const u32, nargs: usize,
) -> u32 {
    if fctx.is_null() || ctx.is_null() || name.is_null() || (nargs > 0 && args.is_null()) {
        return 0;
    }
    unsafe {
        let nm = CStr::from_ptr(name).to_str().unwrap_or("");
        let arg_slice = std::slice::from_raw_parts(args, nargs);
        (*fctx).emit_call_import((*ctx).module_mut(), &(*ctx).imports, nm, arg_slice)
    }
}

#[no_mangle]
pub extern "C" fn function_add_block(fctx: *mut FunctionCtx, name: *const c_char) {
    if fctx.is_null() || name.is_null() { return; }
    unsafe { (*fctx).create_block_named(CStr::from_ptr(name).to_str().unwrap_or("b")) }
}

#[no_mangle]
pub extern "C" fn function_switch_block(fctx: *mut FunctionCtx, name: *const c_char) -> c_int {
    if fctx.is_null() || name.is_null() { return 0; }
    unsafe { if (*fctx).switch_to_named(CStr::from_ptr(name).to_str().unwrap_or("")) { 1 } else { 0 } }
}

#[no_mangle]
pub extern "C" fn function_seal_block(fctx: *mut FunctionCtx, name: *const c_char) {
    if fctx.is_null() || name.is_null() { return; }
    unsafe { (*fctx).seal_block(CStr::from_ptr(name).to_str().unwrap_or("")) }
}

macro_rules! ffi_binop {
    ($name:ident, $method:ident) => {
        #[no_mangle] pub extern "C" fn $name(fctx: *mut FunctionCtx, l: u32, r: u32) -> u32 {
            if fctx.is_null() { return 0; } unsafe { (*fctx).$method(l, r) }
        }
    };
}
macro_rules! ffi_unop {
    ($name:ident, $method:ident) => {
        #[no_mangle] pub extern "C" fn $name(fctx: *mut FunctionCtx, v: u32) -> u32 {
            if fctx.is_null() { return 0; } unsafe { (*fctx).$method(v) }
        }
    };
}
macro_rules! ffi_convert {
    ($name:ident, $method:ident) => {
        #[no_mangle] pub extern "C" fn $name(fctx: *mut FunctionCtx, v: u32, tt: u32) -> u32 {
            if fctx.is_null() { return 0; } unsafe { (*fctx).$method(v, tt) }
        }
    };
}

ffi_binop!(block_add_iadd, emit_iadd);
ffi_binop!(block_add_isub, emit_isub);
ffi_binop!(block_add_imul, emit_imul);
ffi_binop!(block_add_sdiv, emit_sdiv);
ffi_binop!(block_add_udiv, emit_udiv);
ffi_binop!(block_add_srem, emit_srem);
ffi_binop!(block_add_urem, emit_urem);
ffi_binop!(block_add_band, emit_band);
ffi_binop!(block_add_bor, emit_bor);
ffi_binop!(block_add_bxor, emit_bxor);
ffi_binop!(block_add_ishl, emit_ishl);
ffi_binop!(block_add_ushr, emit_ushr);
ffi_binop!(block_add_sshr, emit_sshr);
ffi_binop!(block_add_fadd, emit_fadd);
ffi_binop!(block_add_fsub, emit_fsub);
ffi_binop!(block_add_fmul, emit_fmul);
ffi_binop!(block_add_fdiv, emit_fdiv);
ffi_unop!(block_add_fneg, emit_fneg);
ffi_convert!(block_add_uextend, emit_uextend);
ffi_convert!(block_add_sextend, emit_sextend);
ffi_convert!(block_add_ireduce, emit_ireduce);
// int <-> float conversions (typed — result type tt)
ffi_convert!(block_add_fcvt_from_sint, emit_fcvt_from_sint);
ffi_convert!(block_add_fcvt_from_uint, emit_fcvt_from_uint);
ffi_convert!(block_add_fcvt_to_sint_sat, emit_fcvt_to_sint_sat);
ffi_convert!(block_add_fcvt_to_uint_sat, emit_fcvt_to_uint_sat);
// float width changes (typed — result type tt: F32 for fdemote, F64 for fpromote)
ffi_convert!(block_add_fdemote, emit_fdemote);
ffi_convert!(block_add_fpromote, emit_fpromote);
// float math
ffi_unop!(block_add_sqrt, emit_sqrt);
ffi_unop!(block_add_ceil, emit_fceil);
ffi_unop!(block_add_floor, emit_ffloor);
ffi_unop!(block_add_trunc, emit_ftrunc);
ffi_unop!(block_add_nearest, emit_fnearest);
ffi_unop!(block_add_fabs, emit_fabs);
ffi_binop!(block_add_fcopysign, emit_fcopysign);
// bit ops
ffi_unop!(block_add_clz, emit_clz);
ffi_unop!(block_add_ctz, emit_ctz);
ffi_unop!(block_add_popcnt, emit_popcnt);
ffi_unop!(block_add_bswap, emit_bswap);

#[no_mangle] pub extern "C" fn block_add_iconst(fctx: *mut FunctionCtx, val: i64, ty: u32) -> u32 { if fctx.is_null() || unsafe { (*fctx).is_block_sealed() } { 0 } else { unsafe { (*fctx).emit_iconst(val, ty) } } }
#[no_mangle] pub extern "C" fn block_add_f64const(fctx: *mut FunctionCtx, val: f64) -> u32 { if fctx.is_null() { 0 } else { unsafe { (*fctx).emit_f64const(val) } } }
#[no_mangle] pub extern "C" fn block_add_f32const(fctx: *mut FunctionCtx, val: f32) -> u32 { if fctx.is_null() { 0 } else { unsafe { (*fctx).emit_f32const(val) } } }

#[no_mangle] pub extern "C" fn block_is_sealed(fctx: *mut FunctionCtx) -> u32 { if fctx.is_null() { 0 } else { unsafe { (*fctx).is_block_sealed() as u32 } } }

#[no_mangle] pub extern "C" fn block_add_icmp(fctx: *mut FunctionCtx, c: u32, l: u32, r: u32) -> u32 { if fctx.is_null() { 0 } else { let cc = map_icmp_cond(c); unsafe { (*fctx).emit_icmp(cc, l, r) } } }
#[no_mangle] pub extern "C" fn block_add_fcmp(fctx: *mut FunctionCtx, c: u32, l: u32, r: u32) -> u32 { if fctx.is_null() { 0 } else { let cc = map_fcmp_cond(c); unsafe { (*fctx).emit_fcmp(cc, l, r) } } }
#[no_mangle] pub extern "C" fn block_add_select(fctx: *mut FunctionCtx, cond: u32, t: u32, e: u32) -> u32 { if fctx.is_null() { 0 } else { unsafe { (*fctx).emit_select(cond, t, e) } } }

#[no_mangle] pub extern "C" fn block_add_load(fctx: *mut FunctionCtx, ptr: u32, off: i32, ty: u32) -> u32 { if fctx.is_null() { 0 } else { unsafe { (*fctx).emit_load(ptr, off, ty) } } }
#[no_mangle] pub extern "C" fn block_add_store(fctx: *mut FunctionCtx, ptr: u32, off: i32, val: u32, ty: u32) { if !fctx.is_null() { unsafe { (*fctx).emit_store(ptr, off, val, ty) } } }

#[no_mangle] pub extern "C" fn block_add_return(fctx: *mut FunctionCtx, val: u32) { if !fctx.is_null() { unsafe { (*fctx).emit_return(val) } } }
#[no_mangle] pub extern "C" fn block_add_return_void(fctx: *mut FunctionCtx) { if !fctx.is_null() { unsafe { (*fctx).emit_return_void() } } }
#[no_mangle] pub extern "C" fn block_add_trap(fctx: *mut FunctionCtx) { if !fctx.is_null() && !unsafe { (*fctx).is_block_sealed() } { unsafe { (*fctx).emit_trap() } } }

#[no_mangle] pub extern "C" fn block_add_jump(fctx: *mut FunctionCtx, tgt: *const c_char) { if !fctx.is_null() && !tgt.is_null() { unsafe { (*fctx).emit_jump(CStr::from_ptr(tgt).to_str().unwrap_or("")) } } }
#[no_mangle] pub extern "C" fn block_add_jump_args(fctx: *mut FunctionCtx, tgt: *const c_char, args: *const u32, nargs: usize) { if !fctx.is_null() && !tgt.is_null() { unsafe { (*fctx).emit_jump_with_args(CStr::from_ptr(tgt).to_str().unwrap_or(""), std::slice::from_raw_parts(args, nargs)) } } }
#[no_mangle] pub extern "C" fn block_add_brif(fctx: *mut FunctionCtx, cond: u32, t: *const c_char, e: *const c_char) { if !fctx.is_null() && !t.is_null() && !e.is_null() { unsafe { (*fctx).emit_brif(cond, CStr::from_ptr(t).to_str().unwrap_or(""), CStr::from_ptr(e).to_str().unwrap_or("")) } } }
#[no_mangle] pub extern "C" fn block_add_brif_args(fctx: *mut FunctionCtx, cond: u32, t: *const c_char, t_args: *const u32, tn: usize, e: *const c_char, e_args: *const u32, en: usize) { if !fctx.is_null() && !t.is_null() && !e.is_null() { unsafe { (*fctx).emit_brif_with_args(cond, CStr::from_ptr(t).to_str().unwrap_or(""), std::slice::from_raw_parts(t_args, tn), CStr::from_ptr(e).to_str().unwrap_or(""), std::slice::from_raw_parts(e_args, en)) } } }
#[no_mangle] pub extern "C" fn function_add_block_param(fctx: *mut FunctionCtx, block_name: *const c_char, ty: u32) -> u32 { if fctx.is_null() || block_name.is_null() { 0 } else { unsafe { (*fctx).append_block_param(CStr::from_ptr(block_name).to_str().unwrap_or(""), ty) } } }

#[no_mangle] pub extern "C" fn builder_finalize(ctx: *mut BuilderContext, path: *const c_char) -> c_int {
    if ctx.is_null() || path.is_null() { return -1; }
    unsafe {
        match (*ctx).finalize(&PathBuf::from(CStr::from_ptr(path).to_str().unwrap_or("o"))) {
            Ok(()) => 0,
            Err(e) => { eprintln!("[native-builder] finalize error: {}", e); -1 },
        }
    }
}

#[no_mangle] pub extern "C" fn block_get_ssa_type(fctx: *mut FunctionCtx, id: u32) -> u32 {
    if fctx.is_null() { return TYPE_I64 as u32; }
    unsafe { (*fctx).get_ssa_type(id) }
}

#[no_mangle] pub extern "C" fn link_object_to_so(uo: *const c_char, rl: *const c_char, so: *const c_char) -> c_int {
    if uo.is_null() || rl.is_null() || so.is_null() { -1 } else { unsafe {
        match linker::link_object_to_so(&PathBuf::from(CStr::from_ptr(uo).to_str().unwrap_or("")), &PathBuf::from(CStr::from_ptr(rl).to_str().unwrap_or("")), &PathBuf::from(CStr::from_ptr(so).to_str().unwrap_or(""))) {
            Ok(()) => 0,
            Err(e) => { eprintln!("[native-builder] link error: {}", e); -1 },
        }
    }}
}

#[no_mangle] pub extern "C" fn cleanup_all_builders() {
    if let Ok(mut b) = BUILDERS.lock() { for bp in b.drain(..) { if !bp.0.is_null() { unsafe { let _ = Box::from_raw(bp.0); } } } }
}
