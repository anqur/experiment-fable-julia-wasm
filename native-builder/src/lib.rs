// Native Builder: eDSL API for Julia → Native compilation
// Phase 1: Basic FFI interface stubs

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::sync::Mutex;

// Import our modules (to be implemented)
mod builder;
mod linker;
mod runtime;

// Re-exports for FFI
use builder::{BuilderContext, EdslFunctionBuilder as FunctionBuilder};
use linker::link_object_to_so as linker_link_object_to_so;

// Global builder registry (thread-safe)
static BUILDERS: Mutex<Vec<usize>> = Mutex::new(Vec::new());

/// Create a new builder context for compilation
/// Returns: pointer to BuilderContext or NULL on failure
#[no_mangle]
pub extern "C" fn create_builder() -> *mut BuilderContext {
    let ctx = Box::new(BuilderContext::new());
    let ctx_ptr = Box::into_raw(ctx);
    let ctx_addr = ctx_ptr as usize;

    // Register in global list for cleanup
    if let Ok(mut builders) = BUILDERS.lock() {
        builders.push(ctx_addr);
    }

    ctx_ptr
}

/// Free a builder context and release all resources
#[no_mangle]
pub extern "C" fn free_builder(ctx: *mut BuilderContext) {
    if ctx.is_null() {
        return;
    }

    let ctx_addr = ctx as usize;

    // Remove from global registry
    if let Ok(mut builders) = BUILDERS.lock() {
        builders.retain(|&b| b != ctx_addr);
    }

    // Convert back to Box and drop
    unsafe {
        let _ = Box::from_raw(ctx);
    }
}

/// Add a function to the builder
/// - ctx: Builder context pointer
/// - name: Function name (null-terminated UTF-8 string)
/// - ret_type: Return type as Cranelift type enum
/// - param_types: Array of parameter types
/// - num_params: Number of parameters
/// Returns: pointer to FunctionBuilder or NULL on failure
#[no_mangle]
pub extern "C" fn builder_add_function(
    ctx: *mut BuilderContext,
    name: *const c_char,
    ret_type: u32,
    param_types: *const u32,
    num_params: usize,
) -> *mut FunctionBuilder {
    if ctx.is_null() || name.is_null() || param_types.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        let builder = &mut *ctx;
        let name_str = CStr::from_ptr(name).to_str().unwrap_or("unnamed");
        let types = std::slice::from_raw_parts(param_types, num_params);

        match builder.add_function(name_str, ret_type, types) {
            Some(func_builder) => Box::into_raw(Box::new(func_builder)),
            None => std::ptr::null_mut(),
        }
    }
}

/// Add a block to a function
/// - fb: FunctionBuilder pointer
/// - name: Block name (null-terminated UTF-8 string)
/// Returns: pointer to BlockBuilder or NULL on failure
#[no_mangle]
pub extern "C" fn function_add_block(
    fb: *mut FunctionBuilder,
    name: *const c_char,
) -> *mut builder::BlockBuilder {
    if fb.is_null() || name.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        let func_builder = &mut *fb;
        let name_str = CStr::from_ptr(name).to_str().unwrap_or("block0");

        Box::into_raw(Box::new(func_builder.add_block(name_str)))
    }
}

/// Add integer addition instruction
#[no_mangle]
pub extern "C" fn block_add_iadd(
    bb: *mut builder::BlockBuilder,
    result: *mut u32,
    lhs: u32,
    rhs: u32,
) {
    if bb.is_null() || result.is_null() {
        return;
    }

    unsafe {
        let block = &mut *bb;
        let result_id = block.add_iadd(lhs, rhs);
        *result = result_id;
    }
}

/// Add return instruction
#[no_mangle]
pub extern "C" fn block_add_return(bb: *mut builder::BlockBuilder, value: u32) {
    if bb.is_null() {
        return;
    }

    unsafe {
        let block = &mut *bb;
        block.add_return(value);
    }
}

/// Finalize builder and generate object file
/// - ctx: Builder context pointer
/// - obj_path: Output object file path (null-terminated UTF-8 string)
/// Returns: 0 on success, negative on failure
#[no_mangle]
pub extern "C" fn builder_finalize(ctx: *mut BuilderContext, obj_path: *const c_char) -> c_int {
    if ctx.is_null() || obj_path.is_null() {
        return -1;
    }

    unsafe {
        let builder = &mut *ctx;
        let path_str = CStr::from_ptr(obj_path).to_str().unwrap_or("output.o");
        let path = PathBuf::from(path_str);

        match builder.finalize(&path) {
            Ok(()) => 0,
            Err(_) => -1,
        }
    }
}

/// Link user code object with runtime static library to create final .so
/// - user_object: User-compiled object file path (null-terminated UTF-8 string)
/// - runtime_lib: Runtime static library path (.a file) (null-terminated UTF-8 string)
/// - so_path: Final output shared library path (null-terminated UTF-8 string)
/// Returns: 0 on success, negative on failure
#[no_mangle]
pub extern "C" fn link_object_to_so(user_object: *const c_char, runtime_lib: *const c_char, so_path: *const c_char) -> c_int {
    if user_object.is_null() || runtime_lib.is_null() || so_path.is_null() {
        return -1;
    }

    unsafe {
        let obj_str = CStr::from_ptr(user_object).to_str().unwrap_or("user.o");
        let lib_str = CStr::from_ptr(runtime_lib).to_str().unwrap_or("libnative_runtime.a");
        let so_str = CStr::from_ptr(so_path).to_str().unwrap_or("output.so");

        let user_path = PathBuf::from(obj_str);
        let lib_path = PathBuf::from(lib_str);
        let so_path = PathBuf::from(so_str);

        match linker_link_object_to_so(&user_path, &lib_path, &so_path) {
            Ok(()) => 0,
            Err(_) => -1,
        }
    }
}

// Clean up all remaining builders (for shutdown)
#[no_mangle]
pub extern "C" fn cleanup_all_builders() {
    if let Ok(mut builders) = BUILDERS.lock() {
        for &ctx_addr in builders.iter() {
            if ctx_addr != 0 {
                unsafe {
                    let ctx_ptr = ctx_addr as *mut BuilderContext;
                    let _ = Box::from_raw(ctx_ptr);
                }
            }
        }
        builders.clear();
    }
}