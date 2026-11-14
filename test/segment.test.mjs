import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { cli, project, tmp, readJson, GO, PY } from "./helpers.mjs";

/** split one project and return {pieces, files, lines(file)} */
function split(files) {
  const dir = project(files), work = path.join(tmp(), "w");
  const r = cli(["split", dir, "--work", work]);
  assert.equal(r.code, 0, r.out);
  const P = readJson(path.join(work, "pieces.json"));
  const lines = rel => fs.readFileSync(path.join(dir, rel), "utf8").split("\n");
  return { P, lines, dir, work };
}
const byFile = (P, rel) => P.pieces.filter(p => P.files[p.f].rel === rel);
/** every non-blank line (optionally excluding markdown headings) is covered exactly once */
function assertCovered(P, rel, L, { headings = true } = {}) {
  const cov = new Map();
  for (const p of byFile(P, rel)) for (let i = p.s; i <= p.e; i++) cov.set(i, (cov.get(i) || 0) + 1);
  L.forEach((t, i) => {
    const n = cov.get(i + 1) || 0;
    if (!t.trim()) return;
    if (headings && /^#{1,6}\s/.test(t)) return assert.equal(n, 0, `heading line ${i + 1} must not be a piece`);
    assert.equal(n, 1, `line ${i + 1} (${t.slice(0, 30)}) covered ${n} times`);
  });
}

test("markdown: every content line is in exactly one piece, headings are not pieces", () => {
  const md = "# Title\n\nIntro text.\n\n## Rules\n\n- one\n  - nested\n- two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```js\nconst x = 1;\n\nconst y = 2;\n```\n\nFinal paragraph\nspanning two lines.\n";
  const { P, lines } = split({ "a.md": md });
  assertCovered(P, "a.md", lines("a.md"));
});

test("markdown: tables and fenced code are never split, nested bullets stay with their parent", () => {
  const md = "## T\n\n- parent\n  - child one\n  - child two\n\n| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |\n\n```\nline1\n\nline3\n```\n";
  const { P, lines } = split({ "a.md": md });
  const L = lines("a.md"), ps = byFile(P, "a.md");
  const holder = needle => ps.find(p => L.slice(p.s - 1, p.e).some(l => l.includes(needle)));
  assert.equal(holder("child two"), holder("- parent"), "nested bullets stay with parent");
  assert.equal(holder("| c | d |"), holder("| h1 | h2 |"), "table in one piece");
  assert.equal(holder("line3"), holder("line1"), "fenced block in one piece");
});

test("markdown: long blocks are split at line boundaries into verbatim pieces", () => {
  const long = Array.from({ length: 60 }, (_, i) => `- item ${i} ${"word ".repeat(8)}`).join("\n");
  const { P, lines } = split({ "a.md": `# H\n\n${long}\n` });
  const ps = byFile(P, "a.md");
  assert.ok(ps.length > 1, "split into several pieces");
  assertCovered(P, "a.md", lines("a.md"));
  for (const p of ps) assert.ok(p.w <= 100, `piece too big: ${p.w} words`);
});

test("go: a function keeps its doc comment, bodies with blank lines are not cut apart", () => {
  const { P, lines } = split({ "s.go": GO });
  assertCovered(P, "s.go", lines("s.go"), { headings: false });
  const L = lines("s.go"), ps = byFile(P, "s.go");
  const holder = needle => ps.find(p => L.slice(p.s - 1, p.e).some(l => l.includes(needle)));
  assert.ok(ps.length >= 2, `expected separate pieces per large function, got ${ps.length}`);
  assert.equal(holder("// Handle answers"), holder("func Handle"), "doc comment attached");
  assert.equal(holder("func Handle"), holder("return fmt.Sprintf"), "whole function (incl. blank line in body) in one piece");
  assert.notEqual(holder("func Handle"), holder("func Helper"), "different functions are different pieces");
  assert.equal(holder("// Helper formats"), holder("func Helper"));
  assert.ok(ps.every(p => p.k === "c" && p.lang === "go"));
});

test("python: decorators attach to the next def, indentation continues a unit", () => {
  const { P, lines } = split({ "u.py": PY });
  assertCovered(P, "u.py", lines("u.py"), { headings: false });
  const L = lines("u.py"), ps = byFile(P, "u.py");
  const holder = needle => ps.find(p => L.slice(p.s - 1, p.e).some(l => l.includes(needle)));
  assert.ok(ps.length >= 2);
  assert.equal(holder("@decorator"), holder("def load"));
  assert.equal(holder("def load"), holder("return f.read()"));
  assert.equal(holder("class Cache"), holder("return k"));
  assert.notEqual(holder("def load"), holder("class Cache"));
});

test("long code is split at blank lines, never mid-statement of a short function", () => {
  const body = Array.from({ length: 80 }, (_, i) => `\tstep${i}(a, b, c, d, e, f)`).join("\n\n");
  const { P, lines } = split({ "big.go": `package x\n\nfunc Big() {\n${body}\n}\n` });
  assertCovered(P, "big.go", lines("big.go"), { headings: false });
  assert.ok(byFile(P, "big.go").length > 1);
});

test("column-0 lines inside braces do not start new pieces (brace depth is tracked)", () => {
  const long = n => `"${Array.from({ length: 45 }, (_, i) => `w${n}x${i}`).join(" ")}",`;
  const go = `package x\n\nvar table = []string{\n${long(1)}\n${long(2)}\n${long(3)}\n}\n\nfunc After() {}\n`;
  const { P, lines } = split({ "t.go": go });
  const L = lines("t.go"), ps = byFile(P, "t.go");
  const holder = needle => ps.find(p => L.slice(p.s - 1, p.e).some(l => l.includes(needle)));
  assert.equal(holder("w1x0"), holder("w3x44"), "the whole literal stays in one piece");
  assert.equal(holder("var table"), holder("w2x3"));
});

test("a UTF-8 BOM does not hide a first-line fence or heading (Windows files)", () => {
  const md = "﻿```js\ncode line\n\nmore code\n```\n\ntext after\n";
  const { P, lines } = split({ "b.md": md });
  const L = lines("b.md"), ps = byFile(P, "b.md");
  const holder = needle => ps.find(p => L.slice(p.s - 1, p.e).some(l => l.includes(needle)));
  assert.equal(holder("code line"), holder("more code"), "fenced block stays in one piece");
  const h = split({ "h.md": "﻿# Title\n\nBody text here.\n" });
  assert.ok(!byFile(h.P, "h.md").some(p => h.lines("h.md").slice(p.s - 1, p.e).some(l => l.includes("Title"))), "the BOM'd first heading is a heading, not a piece");
  const go = split({ "b.go": "﻿package x\n\nfunc A() {}\n" });
  assert.ok(byFile(go.P, "b.go").length >= 1);
});
