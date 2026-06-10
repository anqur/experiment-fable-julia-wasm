// V8 differential check: run the wasm parser under Node and compare full
// event streams (tokens + tree ranges) against the native streams recorded
// by examples/parser/build_web.jl.
import { readFile } from "node:fs/promises";
import { instantiateParser } from "./parser_host.mjs";
import { KINDS } from "./parser_meta.js";
import { buildTree, renderTokensHTML, renderBoxesHTML } from "./tree_render.mjs";

const dir = new URL(".", import.meta.url).pathname;
const wasmBytes = await readFile(dir + "parser.wasm");
const expected = JSON.parse(await readFile(dir + "expected_events.json", "utf8"));

const parser = await instantiateParser(wasmBytes);

const kindName = (id) => (KINDS[id] ?? [String(id)])[0];
let TOMBSTONE = -1;
for (const [id, [nm]] of Object.entries(KINDS))
  if (nm === "TOMBSTONE") TOMBSTONE = Number(id);

// both highlight renderers must reproduce the source text exactly once the
// markup is stripped (the layer overlays the textarea, so any drift in text
// content would misalign the editor)
const stripped = (html) =>
  html.replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&amp;/g, "&");
function renderRoundTrip(src, ev) {
  const bytes = new TextEncoder().encode(src);
  const dec = new TextDecoder();
  const roots = buildTree(ev.tokens, ev.nodes, TOMBSTONE);
  const boxes = renderBoxesHTML(roots, bytes, dec, kindName, bytes.length);
  const toks = renderTokensHTML(ev.tokens, bytes, dec, kindName, TOMBSTONE);
  return stripped(boxes) === src && stripped(toks) === src;
}

let fails = 0;
for (const { src, tokens, nodes } of expected) {
  const got = parser.parse(src);
  const okT = JSON.stringify(got.tokens) === JSON.stringify(tokens);
  const okN = JSON.stringify(got.nodes) === JSON.stringify(nodes);
  if (okT && okN && !renderRoundTrip(src, got)) {
    fails++;
    console.log(`FAIL render round-trip: ${JSON.stringify(src)}`);
  } else if (okT && okN) {
    console.log(`ok   ${tokens.length} tokens, ${nodes.length} nodes: ${JSON.stringify(src.slice(0, 40))}`);
  } else {
    fails++;
    console.log(`FAIL ${JSON.stringify(src)}`);
    for (const [what, exp, act] of [["token", tokens, got.tokens], ["node", nodes, got.nodes]]) {
      if (exp.length !== act.length)
        console.log(`  ${what} count: native ${exp.length} vs wasm ${act.length}`);
      for (let i = 0; i < Math.min(exp.length, act.length); i++) {
        if (JSON.stringify(exp[i]) !== JSON.stringify(act[i])) {
          console.log(`  first ${what} diff at ${i + 1}: ${JSON.stringify(exp[i])} vs ${JSON.stringify(act[i])}`);
          break;
        }
      }
    }
  }
}
console.log(fails === 0
  ? `\nPARSER MATCHES NATIVE on all ${expected.length} inputs (V8).`
  : `\n${fails} inputs disagree`);
process.exit(fails === 0 ? 0 : 1);
