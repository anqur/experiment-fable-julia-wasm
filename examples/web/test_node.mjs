// Headless verification of the exact browser path: run the wasm lexer under
// V8 with the JS host and compare against natively-computed token streams.
import { readFile } from "node:fs/promises";
import { instantiateLexer } from "./lexer_host.mjs";

const dir = new URL(".", import.meta.url).pathname;
const wasmBytes = await readFile(dir + "lexer.wasm");
const expected = JSON.parse(await readFile(dir + "expected_tokens.json", "utf8"));

const lexer = await instantiateLexer(wasmBytes);

let fails = 0;
for (const { src, tokens } of expected) {
  const got = lexer.lex(src).tokens;
  const ok =
    got.length === tokens.length &&
    got.every((t, i) => t[0] === tokens[i][0] && t[1] === tokens[i][1] && t[2] === tokens[i][2]);
  if (ok) {
    console.log(`ok   ${got.length} tokens: ${JSON.stringify(src.slice(0, 30))}`);
  } else {
    fails++;
    console.log(`FAIL ${JSON.stringify(src)}`);
    console.log("  expected:", JSON.stringify(tokens.slice(0, 6)));
    console.log("  got:     ", JSON.stringify(got.slice(0, 6)));
  }
}
console.log(fails === 0 ? "\nV8 lexer matches native Julia on all inputs." : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
