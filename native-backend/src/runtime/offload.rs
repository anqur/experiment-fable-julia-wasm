// Offload dispatch table — Phase 3. Phase 1: empty stub.

/// Maximum number of offload functions in the dispatch table.
const MAX_OFFLOADS: usize = 256;

/// Global offload dispatch table. Phase 1: unused.
pub static mut OFFLOAD_TABLE: [Option<unsafe extern "C" fn()>; MAX_OFFLOADS] =
    [None; MAX_OFFLOADS];

/// Register an offload function. Called by the Julia side at module init time.
#[no_mangle]
pub unsafe extern "C" fn __jl_register_offload(idx: i32, func: Option<unsafe extern "C" fn()>) {
    assert!(idx >= 0 && (idx as usize) < MAX_OFFLOADS);
    OFFLOAD_TABLE[idx as usize] = func;
}

/// Call an offload function by index.
#[no_mangle]
pub unsafe extern "C" fn __jl_offload_call(idx: i32) {
    let func = OFFLOAD_TABLE[idx as usize]
        .expect("offload function not registered");
    func();
}
