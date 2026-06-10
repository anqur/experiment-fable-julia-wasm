#!/usr/bin/env node
// Run a WasmCodegen-produced module under V8 (the browser/Node path).
//
// Usage: node run_wasm.mjs <module.wasm> <export> [args...]
//   i64 parameters are passed as BigInt; results print on stdout.
//
// Modules with "julia" offload imports need host bindings; this runner stubs
// them out with throwing functions so pure modules run unmodified (the same
// shape a browser embedding would use).

import { readFile } from "node:fs/promises";

const [, , path, entry, ...rawArgs] = process.argv;
if (!path || !entry) {
  console.error("usage: node run_wasm.mjs <module.wasm> <export> [args...]");
  process.exit(2);
}

const bytes = await readFile(path);
const module = await WebAssembly.compile(bytes);

// Provide throwing stubs for any "julia" offload imports.
const imports = { julia: {} };
for (const im of WebAssembly.Module.imports(module)) {
  if (im.module === "julia" && im.kind === "function") {
    imports.julia[im.name] = () => {
      throw new Error(`offload import ${im.name} not bound in JS host`);
    };
  }
}

const instance = await WebAssembly.instantiate(module, imports);
const fn = instance.exports[entry];
if (typeof fn !== "function") {
  console.error(`export ${entry} not found or not a function`);
  process.exit(2);
}

// JS API: i64 params arrive as BigInt; decide per-argument by trying BigInt
// first and falling back to Number for floats.
const args = rawArgs.map((s) =>
  s.includes(".") || s.includes("e") || s.includes("E") || s === "NaN" || s === "Inf"
    ? Number(s)
    : BigInt(s),
);

try {
  const result = fn(...args);
  console.log(typeof result === "bigint" ? result.toString() : String(result));
} catch (err) {
  console.log(`trap: ${err.message ?? err}`);
  process.exit(1);
}
