// Demo: Load a compiled Julia .so via libloading and call native functions.
//
// This demonstrates the end-to-end flow:
//   1. Julia NativeCodegen + native-backend → .so file
//   2. Rust binary loads the .so and calls the compiled function
//   3. No Julia runtime needed at the consumption site
//
// Build: cargo build
// Run:   cargo run -- <path-to-.so>

use libloading::{Library, Symbol};
use std::env;
use std::ffi::CString;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <path-to-compiled.so> [function-name]", args[0]);
        eprintln!();
        eprintln!("Example flow:");
        eprintln!("  1. julia -e 'using NativeCodegen; compile_native(gcd, Tuple{{Int64,Int64}})'");
        eprintln!("  2. {} path/to/libmodule.so", args[0]);
        std::process::exit(1);
    }

    let lib_path = &args[1];
    let func_name = if args.len() >= 3 { &args[2] } else { "entry" };

    // Load the shared library
    println!("Loading: {}", lib_path);
    let lib = unsafe {
        Library::new(lib_path).expect("Failed to load shared library")
    };

    // Look up the native_compile symbol to verify we can access the backend
    // (In the full flow, the .so IS the compiled module, not the backend)
    println!("Library loaded successfully.");
    println!();

    // Attempt to look up the compiled function
    let func_name_c = CString::new(func_name.as_bytes()).unwrap();
    unsafe {
        let func: Result<Symbol<unsafe extern "C" fn(i64, i64) -> i64>, _> =
            lib.get(func_name_c.as_bytes());
        match func {
            Ok(f) => {
                println!("Found function: {}", func_name);
                // Call with sample args
                let result = f(12, 8);
                println!("  {}(12, 8) = {}", func_name, result);
            }
            Err(_) => {
                println!("Function '{}' not found in library.", func_name);
                println!("Available symbols can be viewed with: nm -gU {}", lib_path);
            }
        }
    }

    println!();
    println!("Demo complete. The compiled .so is a standalone native artifact.");
    println!("No Julia runtime required at this point.");
}
