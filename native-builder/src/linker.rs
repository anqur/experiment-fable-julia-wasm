// Linker integration: Use Julia's built-in lld for Linux ELF linking

use std::path::{Path, PathBuf};
use std::process::Command;
use std::env;

/// Find Julia's nightly lld specifically
pub fn find_julia_lld() -> Option<PathBuf> {
    // Use julia-nightly specifically as requested
    let home = env::var("HOME").ok()?;
    let lld_path = format!(
        "{}/.julia/juliaup/julia-nightly/libexec/julia/lld",
        home
    );

    let path = PathBuf::from(&lld_path);
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

/// Link user code object file with runtime static library to create final .so
/// - user_object: Compiled user code (.o file)
/// - runtime_lib: Runtime static library (.a file)
/// - so_path: Final output shared library path
pub fn link_object_to_so(user_object: &Path, runtime_lib: &Path, so_path: &Path) -> Result<(), String> {
    let lld_path = find_julia_lld().ok_or("lld not found")?;

    println!("Using lld: {:?}", lld_path);
    println!("Linking {:?} + {:?} → {:?}", user_object, runtime_lib, so_path);

    // Run lld with flavor for Unix with static linking
    let status = Command::new(lld_path)
        .arg("-flavor")              // Specify flavor
        .arg("ld.lld")               // Use Unix flavor
        .arg("-shared")              // Generate shared library
        .arg("-o").arg(so_path)      // Output file
        .arg(user_object)            // User-compiled code object
        .arg(runtime_lib)            // Static runtime library
        .status()
        .map_err(|e| format!("Failed to execute lld: {}", e))?;

    if status.success() {
        println!("✅ Linking successful! Self-contained .so created.");
        Ok(())
    } else {
        Err(format!("lld failed with exit code: {:?}", status.code()))
    }
}

/// Get the library search path for GC and other runtime libraries
fn library_path() -> String {
    // For now, use system library paths
    // TODO: Add support for custom library paths
    "/usr/lib".to_string()
}