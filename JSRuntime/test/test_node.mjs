// V8 side of the JSString differential: run each compiled module against the
// expected outcomes recorded by runtests.jl. The "wasm:js-string" imports are
// engine builtins when available ({builtins: ["js-string"]}); otherwise a
// polyfill over real JS strings — semantically identical, since the builtins
// are specified as ordinary imports.
import { readFile } from "node:fs/promises";

const dir = new URL(".", import.meta.url).pathname;
const manifest = JSON.parse(await readFile(dir + "jsstr_manifest.json", "utf8"));

const trap = (msg) => { throw new Error("trap: " + msg); };
const str = (x) => {
  if (typeof x !== "string") trap("not a string");
  return x;
};
const polyfill = {
  test: (x) => (typeof x === "string" ? 1 : 0),
  cast: (x) => str(x),
  length: (s) => str(s).length,
  charCodeAt: (s, i) => {
    i >>>= 0;
    if (i >= str(s).length) trap("charCodeAt OOB");
    return s.charCodeAt(i);
  },
  codePointAt: (s, i) => {
    i >>>= 0;
    if (i >= str(s).length) trap("codePointAt OOB");
    return s.codePointAt(i);
  },
  concat: (a, b) => str(a) + str(b),
  substring: (s, a, b) => {
    a >>>= 0;
    b >>>= 0;
    const len = str(s).length;
    a = Math.min(a, len);
    b = Math.min(b, len);
    return a >= b ? "" : s.substring(a, b);
  },
  equals: (a, b) => (a === b ? 1 : 0),
  fromCharCode: (c) => String.fromCharCode((c >>> 0) & 0xffff),
  fromCodePoint: (c) => {
    c >>>= 0;
    if (c > 0x10ffff) trap("invalid code point");
    return String.fromCodePoint(c);
  },
};

// Prefer real engine builtins (needs the spec-exact-typed module flavor and,
// on Node 22, --experimental-wasm-imported-strings); fall back to the
// polyfill over the portable flavor — semantically identical.
let nbuiltin = 0;
let npolyfill = 0;
async function inst(bytes, exactBytes) {
  try {
    const r = await WebAssembly.instantiate(exactBytes, {}, { builtins: ["js-string"] });
    nbuiltin++;
    return r.instance;
  } catch {
    npolyfill++;
    const r = await WebAssembly.instantiate(bytes, { "wasm:js-string": polyfill });
    return r.instance;
  }
}

let fails = 0;
for (const { name, wasm, entry, cases } of manifest) {
  const bytes = await readFile(dir + wasm);
  const exactBytes = await readFile(dir + wasm.replace(".wasm", "_exact.wasm"));
  const instance = await inst(bytes, exactBytes);
  const fn = instance.exports[entry];
  for (const { args, expected, stringret } of cases) {
    let got;
    try {
      got = fn(...args);
      if (typeof got === "bigint") got = Number(got);
    } catch (e) {
      got = { error: true };
    }
    const exp = expected;
    const ok =
      exp && exp.error ? got && got.error :
      stringret ? got === exp : Number(got) === exp;
    if (!ok) {
      fails++;
      console.log(`FAIL ${name}(${JSON.stringify(args)}) -> ${JSON.stringify(got)} expected ${JSON.stringify(exp)}`);
    }
  }
}
const mode = `${nbuiltin} modules on engine builtins, ${npolyfill} on the polyfill`;
console.log(fails === 0
  ? `JSString V8 differential: all pass (${mode})`
  : `${fails} failures (${mode})`);
process.exit(fails === 0 ? 0 : 1);
