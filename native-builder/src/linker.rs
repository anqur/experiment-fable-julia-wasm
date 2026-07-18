// Linker integration: Use Julia's built-in lld for linking
// macOS: ld64.lld (Mach-O), Linux: ld.lld (ELF)

use std::path::{Path, PathBuf};
use std::process::Command;
use std::env;

/// Find Julia's nightly lld
pub fn find_julia_lld() -> Option<PathBuf> {
    let home = env::var("HOME").ok()?;

    // macOS: lld is inside the .app bundle
    let macos_path = PathBuf::from(format!(
        "{}/.julia/juliaup/julia-nightly/Julia-1.14.app/Contents/Resources/julia/libexec/julia/lld",
        home
    ));
    if macos_path.exists() {
        return Some(macos_path);
    }

    // Linux: lld is in the bin directory
    let linux_path = PathBuf::from(format!(
        "{}/.julia/juliaup/julia-nightly/libexec/julia/lld",
        home
    ));
    if linux_path.exists() {
        return Some(linux_path);
    }

    // Also try system lld
    let sys_path = PathBuf::from("/usr/bin/lld");
    if sys_path.exists() { return Some(sys_path); }
    let sys_path = PathBuf::from("/usr/local/bin/lld");
    if sys_path.exists() { return Some(sys_path); }

    None
}

pub fn link_object_to_so(user_object: &Path, runtime_lib: &Path, so_path: &Path) -> Result<(), String> {
    let lld_path = find_julia_lld().ok_or("lld not found".to_string())?;

    let (flavor, shared_flag) = if cfg!(target_os = "macos") {
        ("ld64.lld", "-dylib")  // Mach-O dynamic library
    } else {
        ("ld.lld", "-shared")   // ELF shared library
    };

    // Gate the per-link progress logs behind NATIVE_BUILDER_VERBOSE so the test
    // suite output (one link per compiled function) is quiet by default.
    let verbose = env::var("NATIVE_BUILDER_VERBOSE").is_ok();
    if verbose {
        eprintln!("[linker] Using lld: {:?}", lld_path);
        eprintln!("[linker] Linking {:?} + {:?} → {:?}", user_object, runtime_lib, so_path);
    }

    let mut cmd = Command::new(&lld_path);
    cmd.arg("-flavor")
       .arg(flavor)
       .arg(shared_flag)
       .arg("-o").arg(so_path)
       .arg(user_object)
       .arg(runtime_lib);

    // macOS: specify architecture.  The .so may have undefined libSystem symbols
    // (bzero, memcpy, abort, __Unwind_Resume, Cranelift libcalls, etc.) which
    // resolve at dlopen time against the host process's libSystem — these are
    // legitimate.  libjulia symbols (jl_alloc_*, jl_array_*) must NOT appear as
    // undefined — we verify this after linking (see verify_no_julia_symbols).
    if cfg!(target_os = "macos") {
        let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" };
        cmd.arg("-arch").arg(arch);
        cmd.arg("-undefined").arg("dynamic_lookup");
        cmd.arg("-platform_version").arg("macos").arg("14.0").arg("14.0");
    }
    // Linux: allow undefined libc/libm symbols.
    if cfg!(target_os = "linux") {
        // ELF allows undefined by default — no flag needed
    }

    let output = cmd.output().map_err(|e| format!("Failed to execute lld: {}", e))?;

    if output.status.success() {
        if verbose { eprintln!("[linker] Linking successful → {:?}", so_path); }
        verify_no_julia_symbols(so_path)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        Err(format!("lld failed: {}\nstdout: {}\nstderr: {}", output.status, stdout, stderr))
    }
}

/// Verify the .so has no undefined libjulia symbols.  On macOS, `nm -u`
/// lists undefined symbols; we grep for `jl_` (lowercase, matches
/// `_jl_alloc_string`, `_jl_array_grow_end`, etc.).  The `.so` may have
/// undefined libSystem/libc symbols — those are legitimate.
///
/// CAVEAT: this only catches *undefined-symbol references*. It does NOT catch
/// baked Julia-heap pointer *immediates* (mov/movk constants in .text) — those
/// are the real standalone-dependency hazard and are guarded at EMIT time
/// (NativeCodegen/src/builder_emit.jl `_trace_bake` / `NCG_STRICT_BAKE`), not
/// here. The end-to-end guard is the pure-Rust standalone demo
/// (examples/native_demo) loading the .so without Julia present.
fn verify_no_julia_symbols(so_path: &Path) -> Result<(), String> {
    let output = Command::new("nm")
        .arg("-u")
        .arg(so_path)
        .output()
        .map_err(|e| format!("Failed to run nm: {}", e))?;

    // nm writes symbol names to stdout; stderr is empty on success
    let stdout = String::from_utf8_lossy(&output.stdout);
    // macOS nm -u output: each line is a symbol name (with leading underscore)
    // Linux nm -u output: "                 U symbol_name"
    for line in stdout.lines() {
        let sym = line.trim().trim_start_matches('U').trim().trim_start_matches('_');
        // Catch any jl_ C-API symbol.  Our runtime functions are __jl_ prefix
        // (double underscore) — those are defined, not undefined.
        if sym.starts_with("jl_") {
            return Err(format!(
                "FATAL: .so has undefined libjulia symbol: {}. The .so must be self-contained with zero libjulia dependency.",
                sym
            ));
        }
    }
    Ok(())
}
