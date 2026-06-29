// Demo: Load a compiled Julia .so via libloading and call native functions.
//
// This demonstrates the end-to-end flow:
//   1. Julia NativeCodegen + native-backend → .so file
//   2. Rust binary loads the .so and calls the compiled function
//   3. No Julia runtime needed at the consumption site
//
// Build: cargo build
// Run:   cargo run -- <path-to-.so> [function-name]

use libloading::{Library, Symbol};
use std::env;
use std::ffi::CString;

// JuliaSyntax demo function types
type StringFunction = unsafe extern "C" fn(*const u8, i32) -> *mut u8;
type Int64Function = unsafe extern "C" fn(i64, i64) -> i64;

// Runtime functions we'll need
type StringLenFn = unsafe extern "C" fn(*const u8) -> i32;
type StringGetFn = unsafe extern "C" fn(*const u8, i32) -> u8;

fn demo_basic_math(lib: &Library, func_name: &str) {
    let func_name_c = CString::new(func_name.as_bytes()).unwrap();
    unsafe {
        let func: Result<Symbol<Int64Function>, _> = lib.get(func_name_c.as_bytes());
        match func {
            Ok(f) => {
                println!("Found function: {}", func_name);
                // Test with sample args
                let result = f(12, 8);
                println!("  {}(12, 8) = {}", func_name, result);
            }
            Err(_) => {
                println!("Function '{}' not found in library.", func_name);
            }
        }
    }
}

fn demo_juliasyntax_parsing(lib: &Library) {
    println!("\n=== JuliaSyntax Demo ===");

    // Get runtime functions
    let string_len: Result<Symbol<StringLenFn>, _> = unsafe {
        lib.get(b"__jl_string_len\0")
    };

    let string_get: Result<Symbol<StringGetFn>, _> = unsafe {
        lib.get(b"__jl_string_get\0")
    };

    // Look for a simple string processing function
    let tokenize_func: Result<Symbol<StringFunction>, _> = unsafe {
        lib.get(b"tokenize\0")
    };

    match (tokenize_func, string_len, string_get) {
        (Ok(tokenize), Ok(str_len), Ok(str_get)) => {
            println!("Found JuliaSyntax tokenize function");

            // Create a test string
            let test_input = "x + y";
            let input_ptr = test_input.as_ptr();
            let input_len = test_input.len() as i32;

            unsafe {
                println!("Tokenizing: '{}'", test_input);

                // Call tokenize function
                let result_ptr = tokenize(input_ptr, input_len);

                if !result_ptr.is_null() {
                    let len = str_len(result_ptr);
                    println!("Result length: {}", len);

                    // Try to read first few bytes
                    if len > 0 {
                        let first_char = str_get(result_ptr, 0) as char;
                        println!("First character: '{}'", first_char);
                    }

                    println!("Tokenize succeeded!");
                } else {
                    println!("Tokenize returned null");
                }
            }
        }
        _ => {
            println!("JuliaSyntax functions not found in library.");
            println!("This is expected if the library wasn't compiled with JuliaSyntax support.");
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <path-to-compiled.so> [function-name]", args[0]);
        eprintln!();
        eprintln!("Example flow:");
        eprintln!("  1. julia -e 'using NativeCodegen; compile_native(gcd, Tuple{{Int64,Int64}})'");
        eprintln!("  2. {} path/to/libmodule.so", args[0]);
        eprintln!();
        eprintln!("JuliaSyntax example:");
        eprintln!("  1. julia -e 'using NativeCodegen; compile_native(tokenize, Tuple{{String}})'");
        eprintln!("  2. {} path/to/libmodule.so tokenize", args[0]);
        std::process::exit(1);
    }

    let lib_path = &args[1];
    let func_name = if args.len() >= 3 { &args[2] } else { "entry" };

    // Load the shared library
    println!("Loading: {}", lib_path);
    let lib = unsafe {
        Library::new(lib_path).expect("Failed to load shared library")
    };

    println!("Library loaded successfully.");

    // Run basic math demo
    demo_basic_math(&lib, func_name);

    // Run JuliaSyntax demo
    demo_juliasyntax_parsing(&lib);

    println!();
    println!("Demo complete. The compiled .so is a standalone native artifact.");
    println!("No Julia runtime required at this point.");
}
