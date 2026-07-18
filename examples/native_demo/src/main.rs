// Standalone Julia-syntax parser demo.
//
// Loads a `.so` produced by NativeCodegen (compiled from a Julia function of
// signature `f(s::String)::Int`) and calls it from PURE RUST — no Julia runtime
// loaded. The `.so` is self-contained: it carries its own GC arena, type-tag
// registry, and string/const-table bytes, so it does not depend on the Julia
// process that compiled it.
//
//   cargo run -- <path-to-.so> "any julia input"
//
// The arg String is built by the `.so`'s OWN runtime helper `__jl_string_from_raw`
// (Julia-compatible layout: length@0, bytes@8). The entry returns an Int64
// (GreenNode count for parse_into). `__jl_gc_reset` frees the leak-arena between
// inputs.

use libloading::{Library, Symbol};
use std::env;
use std::ffi::CString;

type EntryFn = unsafe extern "C" fn(*mut u8) -> i64;
type StringFromRawFn = unsafe extern "C" fn(*const u8, i32) -> *mut u8;
type GcResetFn = unsafe extern "C" fn();

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <path-to-compiled.so> [julia source] [entry-symbol]", args[0]);
        eprintln!();
        eprintln!("Compiles parse_into(src::String)::Int with NativeCodegen, then:");
        eprintln!("  {} /tmp/ncg_parse.so \"1 + 2\"", args[0]);
        std::process::exit(1);
    }
    let lib_path = &args[1];
    let input = args.get(2).map(|s| s.as_str()).unwrap_or("1 + 2");
    let entry_sym = args.get(3).map(|s| s.as_str()).unwrap_or("__jl_entry_parse_into");

    println!("Loading: {}", lib_path);
    let lib = unsafe { Library::new(lib_path).expect("Failed to load shared library") };
    println!("Library loaded (no Julia runtime present).");

    let entry_name = CString::new(entry_sym).unwrap();
    let entry: Symbol<EntryFn> = unsafe {
        lib.get(entry_name.as_bytes())
            .expect("entry symbol not found in .so")
    };
    let string_from_raw: Symbol<StringFromRawFn> = unsafe {
        lib.get(b"__jl_string_from_raw\0")
            .expect("__jl_string_from_raw not found in .so")
    };
    let gc_reset: Option<Symbol<GcResetFn>> = unsafe { lib.get(b"__jl_gc_reset\0").ok() };

    // Build the Julia-compatible String arg via the .so's own runtime.
    let bytes = input.as_bytes();
    let string_ptr = unsafe { string_from_raw(bytes.as_ptr(), bytes.len() as i32) };
    if string_ptr.is_null() {
        eprintln!("__jl_string_from_raw returned null");
        std::process::exit(1);
    }

    println!("Parsing standalone: {:?}", input);
    let result = unsafe { entry(string_ptr) };
    println!("  → entry returned: {}", result);

    if let Some(reset) = gc_reset {
        unsafe { reset() };
    }
    println!("Demo complete — .so is standalone (zero Julia dependency).");
}
