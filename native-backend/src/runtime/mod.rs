// Rust runtime for compiled Julia code.
//
// Phase 1: minimal stubs — malloc-based allocation, abort on throw.
// Phases 2-3 will fill in Boehm GC, setjmp/longjmp EH, strings, offloads.

pub mod gc;
pub mod exceptions;
pub mod strings;
pub mod offload;
pub mod parse_bridge;
