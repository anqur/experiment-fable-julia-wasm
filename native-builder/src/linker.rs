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

    eprintln!("[linker] Using lld: {:?}", lld_path);
    eprintln!("[linker] Linking {:?} + {:?} → {:?}", user_object, runtime_lib, so_path);

    let mut cmd = Command::new(&lld_path);
    cmd.arg("-flavor")
       .arg(flavor)
       .arg(shared_flag)
       .arg("-o").arg(so_path)
       .arg(user_object)
       .arg(runtime_lib);

    // macOS: specify architecture and allow undefined symbols
    if cfg!(target_os = "macos") {
        let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" };
        cmd.arg("-arch").arg(arch);
        cmd.arg("-undefined").arg("dynamic_lookup");
        cmd.arg("-platform_version").arg("macos").arg("14.0").arg("14.0");
    }

    let output = cmd.output().map_err(|e| format!("Failed to execute lld: {}", e))?;

    if output.status.success() {
        eprintln!("[linker] Linking successful → {:?}", so_path);
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        Err(format!("lld failed: {}\nstdout: {}\nstderr: {}", output.status, stdout, stderr))
    }
}
