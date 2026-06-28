// Cranelift JIT compiler: parse CLIF text → compile to native code → return fn ptr.

use cranelift_codegen::ir::Function;
use cranelift_codegen::Context;
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{Module, Linkage};
use cranelift_reader::parse_functions;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::c_char;

/// A compiled native module holding function pointers, keyed by name.
pub struct CompiledModule {
    /// Map from function name (e.g. "gcd") to raw function pointer.
    pub functions: HashMap<String, *const u8>,
    /// The JIT module — must be kept alive while functions are callable.
    pub jit_module: JITModule,
}

/// Compile CLIF text into native machine code.
/// Returns a CompiledModule with callable function pointers.
pub fn compile_clif(source: &str) -> Result<CompiledModule, String> {
    // Parse CLIF text into Function IR
    let functions: Vec<Function> = parse_functions(source)
        .map_err(|e| format!("CLIF parse error: {}", e))?;

    if functions.is_empty() {
        return Err("no functions found in CLIF source".to_string());
    }

    // Set up JIT with runtime symbols
    let mut jit_builder = JITBuilder::new(
        cranelift_module::default_libcall_names()
    ).map_err(|e| format!("JIT builder error: {}", e))?;

    // Register runtime functions so CLIF calls can resolve them
    jit_builder
        .symbol("__jl_gc_alloc", crate::runtime::gc::__jl_gc_alloc as *const u8)
        .symbol("__jl_gc_alloc_array", crate::runtime::gc::__jl_gc_alloc_array as *const u8)
        .symbol("__jl_gc_array_len", crate::runtime::gc::__jl_gc_array_len as *const u8)
        .symbol("__jl_gc_type_tag", crate::runtime::gc::__jl_gc_type_tag as *const u8);

    let mut jit_module = JITModule::new(jit_builder);
    let mut func_ids = Vec::new();
    let mut ctx = Context::new();

    // Declare and define each function
    for func in &functions {
        let name = func.name.to_string();
        let sig = func.signature.clone();

        // Declare the function in the JIT module
        let func_id = jit_module
            .declare_function(&name, Linkage::Export, &sig)
            .map_err(|e| format!("declare error for '{}': {}", name, e))?;

        // Set up the compilation context with the parsed function
        ctx.func = func.clone();

        // Define (compile) the function
        jit_module
            .define_function(func_id, &mut ctx)
            .map_err(|e| format!("compile error for '{}': {}", name, e))?;

        func_ids.push((name, func_id));
    }

    // Finalize all definitions (apply relocations, make memory executable)
    jit_module
        .finalize_definitions()
        .map_err(|e| format!("finalize error: {}", e))?;

    // Collect function pointers
    let mut func_map = HashMap::new();
    for (name, func_id) in &func_ids {
        let ptr = jit_module.get_finalized_function(*func_id);
        func_map.insert(name.clone(), ptr);
    }

    Ok(CompiledModule {
        functions: func_map,
        jit_module,
    })
}

/// Compile CLIF text from C string. Returns an opaque module handle, or null on error.
#[no_mangle]
pub unsafe extern "C" fn native_compile(
    source: *const c_char,
    len: usize,
) -> *mut CompiledModule {
    if source.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let slice = std::slice::from_raw_parts(source as *const u8, len);
    let text = match std::str::from_utf8(slice) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    match compile_clif(text) {
        Ok(module) => Box::into_raw(Box::new(module)),
        Err(e) => {
            eprintln!("native_compile: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Look up a function pointer by name in a compiled module.
#[no_mangle]
pub unsafe extern "C" fn native_lookup(
    module: *const CompiledModule,
    name: *const c_char,
) -> *const u8 {
    if module.is_null() || name.is_null() {
        return std::ptr::null();
    }
    let module = &*module;
    let cstr = CStr::from_ptr(name);
    let name_str = match cstr.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null(),
    };
    module.functions.get(name_str).copied().unwrap_or(std::ptr::null())
}

/// Free a compiled module and all its functions.
#[no_mangle]
pub unsafe extern "C" fn native_free(module: *mut CompiledModule) {
    if !module.is_null() {
        drop(Box::from_raw(module));
    }
}
