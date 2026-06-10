// V8 differential check: run the wasm parser under Node and compare full
// event streams (post-order RawGreenNode events) against the native streams
// recorded by examples/parser/build_web.jl, across syntax versions.
import { readFile } from "node:fs/promises";
import { instantiateParser } from "./parser_host.mjs";
import { KINDS } from "./parser_meta.js";
import { buildTree, tokensFromEvents, renderTokensHTML, collectBoxes,
         byteToCharMap } from "./tree_render.mjs";

const dir = new URL(".", import.meta.url).pathname;
const wasmBytes = await readFile(dir + "parser.wasm");
const expected = JSON.parse(await readFile(dir + "expected_events.json", "utf8"));

const parser = await instantiateParser(wasmBytes);

const kindName = (id) => (KINDS[id] ?? [String(id)])[0];
let TOMBSTONE = -1;
for (const [id, [nm]] of Object.entries(KINDS))
  if (nm === "TOMBSTONE") TOMBSTONE = Number(id);

// the token highlighter must reproduce the source text exactly once markup
// is stripped (the layer overlays the editor, so any drift in text content
// would misalign it); the box helpers must produce parents-first boxes with
// in-bounds byte ranges that translate cleanly to char offsets
const stripped = (html) =>
  html.replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&amp;/g, "&");
function renderRoundTrip(src, events) {
  const bytes = new TextEncoder().encode(src);
  const dec = new TextDecoder();
  const tokens = tokensFromEvents(events);
  const toks = renderTokensHTML(tokens, bytes, dec, kindName);
  if (stripped(toks) !== src) return false;
  const b2c = byteToCharMap(src);
  if (b2c.length !== bytes.length + 1 || b2c[bytes.length] !== src.length)
    return false;
  const roots = buildTree(events, bytes.length, TOMBSTONE);
  const boxes = collectBoxes(roots, kindName);
  const open = []; // paint order must be a valid nesting walk
  for (const box of boxes) {
    if (box.a < 1 || box.b > bytes.length || b2c[box.b] < b2c[box.a - 1])
      return false;
    while (open.length && !(box.a >= open[open.length - 1].a &&
                            box.b <= open[open.length - 1].b))
      open.pop();
    if (box.depth !== open.length && !box.err) return false;
    open.push(box);
  }
  return true;
}

let fails = 0;
for (const { src, v, events } of expected) {
  const got = parser.parse(src, v);
  const ok = JSON.stringify(got.events) === JSON.stringify(events);
  if (ok && !renderRoundTrip(src, got.events)) {
    fails++;
    console.log(`FAIL render round-trip (v1.${v}): ${JSON.stringify(src)}`);
  } else if (ok) {
    console.log(`ok   ${events.length} events (v1.${v}): ${JSON.stringify(src.slice(0, 40))}`);
  } else {
    fails++;
    console.log(`FAIL v1.${v} ${JSON.stringify(src)}`);
    if (events.length !== got.events.length)
      console.log(`  event count: native ${events.length} vs wasm ${got.events.length}`);
    for (let i = 0; i < Math.min(events.length, got.events.length); i++) {
      if (JSON.stringify(events[i]) !== JSON.stringify(got.events[i])) {
        console.log(`  first diff at ${i + 1}: ${JSON.stringify(events[i])} vs ${JSON.stringify(got.events[i])}`);
        break;
      }
    }
  }
}
console.log(fails === 0
  ? `\nPARSER MATCHES NATIVE on all ${expected.length} inputs (V8).`
  : `\n${fails} inputs disagree`);
process.exit(fails === 0 ? 0 : 1);
