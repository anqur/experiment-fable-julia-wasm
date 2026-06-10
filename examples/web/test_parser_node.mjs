// V8 differential check: run the wasm parser under Node and compare full
// event streams (tokens + tree ranges) against the native streams recorded
// by examples/parser/build_web.jl.
import { readFile } from "node:fs/promises";
import { instantiateParser } from "./parser_host.mjs";

const dir = new URL(".", import.meta.url).pathname;
const wasmBytes = await readFile(dir + "parser.wasm");
const expected = JSON.parse(await readFile(dir + "expected_events.json", "utf8"));

const parser = await instantiateParser(wasmBytes);

let fails = 0;
for (const { src, tokens, nodes } of expected) {
  const got = parser.parse(src);
  const okT = JSON.stringify(got.tokens) === JSON.stringify(tokens);
  const okN = JSON.stringify(got.nodes) === JSON.stringify(nodes);
  if (okT && okN) {
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
