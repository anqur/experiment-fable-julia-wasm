// JS host for the wasm-compiled JuliaSyntax parser. Works in Node 22+ and any
// browser with WasmGC.
//
// Host support needed beyond the lexer's (codeunit/ncodeunits/egal/consts):
//   - emit_token / emit_node: the parser event sinks
//   - _hb_* byte bridge: wasm streams bytes of a string it built; the host
//     interns it (_hb_string) or parses it as a float (_hb_parse_f64/f32,
//     mirroring strtod incl. hexfloats and the ERANGE status convention)
//   - repr / print_to_string / _string: string formatting for diagnostic
//     messages (cosmetic: messages stay inside the wasm-side ParseStream)

import { HOSTCONSTS, IMPORTS } from "./parser_meta.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function hostString(str) {
  return { bytes: encoder.encode(str), str };
}

function refToString(x) {
  if (x === null || x === undefined) return "nothing";
  if (typeof x === "object") {
    if (x.str !== undefined) return x.str;
    if (x.sym !== undefined) return x.sym;
  }
  return String(x);
}

// Julia Char carries its UTF-8 bytes left-aligned in 32 bits
function charBitsToString(u) {
  u = u >>> 0;
  const bytes = [];
  for (let sh = 24; sh >= 0; sh -= 8) {
    const b = (u >>> sh) & 0xff;
    if (bytes.length > 0 && b === 0) break;
    bytes.push(b);
  }
  while (bytes.length > 1 && bytes[bytes.length - 1] === 0) bytes.pop();
  return decoder.decode(new Uint8Array(bytes));
}

function reprChar(u) {
  const s = charBitsToString(u);
  const esc =
    s === "\\" ? "\\\\" : s === "'" ? "\\'" :
    s === "\n" ? "\\n" : s === "\t" ? "\\t" : s === "\r" ? "\\r" : s;
  return `'${esc}'`;
}

function reprString(s) {
  return JSON.stringify(s);
}

// strtod emulation: decimal via parseFloat, hexfloats by hand (JS Number()
// can't parse them). Returns [value, status] with the ERANGE convention used
// by JuliaSyntax: 0 ok, 1 underflow, 2 overflow.
function strtod(s) {
  s = s.trim();
  let v;
  const hex = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(s);
  if (hex) {
    const [, sign, intpart = "", fracpart = "", exppart] = hex;
    let digits = 0n;
    for (const c of intpart + fracpart) digits = digits * 16n + BigInt(parseInt(c, 16));
    const e2 = (exppart !== undefined ? parseInt(exppart, 10) : 0) - 4 * fracpart.length;
    v = Number(digits) * Math.pow(2, e2); // Number(BigInt) rounds to nearest
    if (sign === "-") v = -v;
  } else {
    v = parseFloat(s);
  }
  const mantNonzero = /[1-9a-fA-F]/.test(s.replace(/[pPeE][+-]?\d+$/, ""));
  const status = !isFinite(v) ? 2 : v === 0 && mantNonzero ? 1 : 0;
  return [v, status];
}

export async function instantiateParser(wasmBytes) {
  let tokenSink = [];
  let nodeSink = [];
  let hbuf = [];
  let hbStatus = 0;
  const imports = { julia: {} };

  for (const name of IMPORTS) {
    let fn;
    if (name.includes("emit_token")) {
      fn = (a, b, c) => { tokenSink.push([Number(a), Number(b), Number(c)]); };
    } else if (name.includes("emit_node")) {
      fn = (a, b, c) => { nodeSink.push([Number(a), Number(b), Number(c)]); };
    } else if (name.includes("ncodeunits")) {
      fn = (s) => BigInt(s.bytes.length);
    } else if (name.includes("codeunit")) {
      fn = (s, i) => {
        const idx = Number(i) - 1;
        if (idx < 0 || idx >= s.bytes.length) throw new Error("codeunit OOB");
        return s.bytes[idx];
      };
    } else if (name.includes("egal")) {
      fn = (a, b) =>
        a === b || (a?.str !== undefined && b?.str !== undefined && a.str === b.str)
          ? 1
          : 0;
    } else if (name.includes("_hb_reset")) {
      fn = () => { hbuf = []; };
    } else if (name.includes("_hb_push")) {
      fn = (b) => { hbuf.push(Number(b) & 0xff); };
    } else if (name.includes("_hb_status")) {
      fn = () => hbStatus;
    } else if (name.includes("_hb_parse_f64")) {
      fn = () => {
        const [v, st] = strtod(decoder.decode(new Uint8Array(hbuf)));
        hbStatus = st;
        return v;
      };
    } else if (name.includes("_hb_parse_f32")) {
      fn = () => {
        const s = decoder.decode(new Uint8Array(hbuf));
        let [v, st] = strtod(s);
        const v32 = Math.fround(v);
        if (st === 0 && !isFinite(v32)) st = 2;
        if (st === 0 && v32 === 0 && v !== 0) st = 1;
        hbStatus = st;
        return v32;
      };
    } else if (name.includes("_hb_string")) {
      fn = () => hostString(decoder.decode(new Uint8Array(hbuf)));
    } else if (name.includes("repr")) {
      fn = (x) =>
        hostString(typeof x === "object" && x !== null
          ? reprString(refToString(x))
          : reprChar(Number(x)));
    } else if (name.includes("print_to_string") || name.includes("_string")) {
      fn = (...args) =>
        hostString(args.map((a) =>
          typeof a === "bigint" ? a.toString() :
          typeof a === "number" ? String(a) : refToString(a)).join(""));
    } else {
      fn = () => { throw new Error(`unexpected host import ${name}`); };
    }
    imports.julia[name] = fn;
  }

  HOSTCONSTS.forEach(([name, kind, value], k) => {
    const obj = kind === "string" ? hostString(value) : { hostconst: k, sym: value };
    imports.julia[name] = new WebAssembly.Global(
      { value: "externref", mutable: false },
      obj,
    );
  });

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const parse_into = instance.exports.parse_into;

  return {
    parse(text) {
      tokenSink = [];
      nodeSink = [];
      const n = Number(parse_into(hostString(text)));
      return {
        ntokens: Math.floor(n / 1000000),
        nnodes: n % 1000000,
        tokens: tokenSink,
        nodes: nodeSink,
      };
    },
  };
}
