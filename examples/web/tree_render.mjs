// Shared rendering helpers for the parser demo: green-tree reconstruction
// from the wasm event streams (mirror of JuliaSyntax.build_tree) and the two
// highlight-layer renderers — per-token color cycling and nested parse-tree
// bounding boxes. DOM-free (returns HTML strings) so the node test can check
// them headlessly.

export const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

// Token/range indices are 1-based (token 1 is the parser's sentinel); byte
// ranges are 1-based inclusive.
export function buildTree(tokens, ranges, TOMBSTONE) {
  const stack = [];
  let i = 1, j = 0;
  while (true) {
    const lastToken = j < ranges.length ? ranges[j][2] : tokens.length;
    while (i <= lastToken) {
      const [head, , nextByte] = tokens[i - 1];
      if ((head & 0xffff) === TOMBSTONE) { i++; continue; }
      stack.push({ firstToken: i, node: {
        head, a: tokens[i - 2][2], b: nextByte - 1, leaf: true } });
      i++;
    }
    if (j >= ranges.length) break;
    while (j < ranges.length) {
      const [head, firstToken, lt] = ranges[j];
      if (lt !== lastToken) break;
      if ((head & 0xffff) === TOMBSTONE) { j++; continue; }
      let k = stack.length;
      while (k > 0 && firstToken <= stack[k - 1].firstToken) k--;
      const children = stack.slice(k).map((e) => e.node);
      const node = { head,
        a: tokens[firstToken - 2][2], b: tokens[lt - 1][2] - 1, children };
      stack.length = k;
      stack.push({ firstToken, node });
      j++;
    }
  }
  return stack.map((e) => e.node);
}

const NCOLORS = 6;
const isErrName = (name) => name.startsWith("Error") || name === "error";

// Mode 1: each non-whitespace token gets the next color in the palette
// (token i spans bytes [tokens[i-1].next_byte, tokens[i].next_byte - 1])
export function renderTokensHTML(tokens, bytes, dec, kindName, TOMBSTONE) {
  let html = "";
  let ci = 0;
  for (let i = 2; i <= tokens.length; i++) {
    const [head, , nextByte] = tokens[i - 1];
    const kind = head & 0xffff;
    const name = kindName(kind);
    const a = tokens[i - 2][2], b = nextByte - 1;
    if (kind === TOMBSTONE || name === "EndMarker" || b < a) continue;
    const piece = dec.decode(bytes.subarray(a - 1, b));
    const isWs = name === "Whitespace" || name === "NewlineWs";
    let cls = "";
    if (isErrName(name)) {
      cls = "tok-error";
    } else if (!isWs) {
      cls = "c" + (ci % NCOLORS);
      ci++;
    }
    html += cls
      ? `<span class="${cls}" data-tok="${name}" title="${name}">${esc(piece)}</span>`
      : esc(piece);
  }
  return html;
}

// Mode 2: nested bounding boxes around interior parse-tree nodes,
// depth-cycled colors; error nodes (and error leaf tokens) in red
export function renderBoxesHTML(roots, bytes, dec, kindName, srcLen) {
  const text = (a, b) => (b < a ? "" : esc(dec.decode(bytes.subarray(a - 1, b))));
  function rec(node, depth) {
    const name = kindName(node.head & 0xffff);
    const isErr = isErrName(name);
    if (node.leaf) {
      const t = text(node.a, node.b);
      return isErr ? `<span class="nb nb-err" title="${esc(name)}">${t}</span>` : t;
    }
    let out = "";
    let pos = node.a;
    for (const c of node.children) {
      if (c.a > pos) out += text(pos, c.a - 1);
      out += rec(c, depth + 1);
      pos = Math.max(pos, c.b + 1);
    }
    if (pos <= node.b) out += text(pos, node.b);
    const cls = isErr ? "nb nb-err" : `nb b${depth % NCOLORS}`;
    return `<span class="${cls}" title="[${esc(name)}]">${out}</span>`;
  }
  let html = "";
  let pos = 1;
  for (const r of roots) {
    if (r.a > pos) html += text(pos, r.a - 1);
    html += rec(r, 0);
    pos = Math.max(pos, r.b + 1);
  }
  if (pos <= srcLen) html += text(pos, srcLen);
  return html;
}
