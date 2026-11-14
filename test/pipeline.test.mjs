import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { cli, applyEdits, validate, buildEditor, sampleProject, tmp, readJson, fakeAgents, fakeDescriptions } from "./helpers.mjs";

/** run the whole deterministic pipeline with fake agents; returns paths */
function pipeline() {
  const dir = sampleProject(), cwd = tmp("wb-out-"), work = path.join(cwd, "w");
  assert.equal(cli(["split", dir, "--work", work]).code, 0);
  const groups = readJson(path.join(work, "groups.json"));
  fakeAgents(work);
  return { dir, cwd, work, groups };
}

test("split forms about sqrt(N) groups with windows covering every piece exactly once", () => {
  const { work, groups } = pipeline();
  const P = readJson(path.join(work, "pieces.json"));
  assert.equal(groups.length, 3, "11 files -> 3 groups");
  const seen = new Set();
  for (const g of groups) for (const w of g.windows) for (let i = w.from; i <= w.to; i++) { assert.ok(!seen.has(i)); seen.add(i); }
  assert.equal(seen.size, P.pieces.length);
  const args = JSON.parse(cli(["groups-args", "--work", work]).stdout);
  assert.equal(args.groups.length, groups.length);
});

test("window instructions contain the code-inversion rules only when the window has code", () => {
  const { work, groups } = pipeline();
  const P = readJson(path.join(work, "pieces.json"));
  let sawCode = false, sawDocOnly = false;
  for (const g of groups) for (const w of g.windows) {
    const out = cli(["window", String(g.g), String(w.w), "--work", work]).stdout;
    const hasCode = P.pieces.slice(w.from - 1, w.to).some(p => p.k === "c");
    assert.equal(/INVERT THE CODE INTO SPECIFICATION/.test(out), hasCode);
    hasCode ? (sawCode = true) : (sawDocOnly = true);
  }
  assert.ok(sawCode && sawDocOnly, "fixture should exercise both");
});

test("check accepts good output and names the problem in bad output", () => {
  const { work, groups } = pipeline();
  assert.equal(cli(["check-all", "--work", work]).stdout.includes('"failing":[]'), true);
  const g = groups[0], w = g.windows[0], f = path.join(work, "out", `g${g.g}-w${w.w}.txt`);
  const good = fs.readFileSync(f, "utf8"), lines = good.trim().split("\n");
  const bad = (text, re) => { fs.writeFileSync(f, text); const r = cli(["check", String(g.g), String(w.w), "--work", work]); assert.equal(r.code, 1); assert.match(r.out, re); };
  bad(lines.slice(1).join("\n") + "\n", /ids missing/);
  bad([lines[0], lines[0], ...lines.slice(1)].join("\n") + "\n", /appears twice|duplicates/);
  bad(good.replace(/Piece (\d+)/, "Piece"), /must be 2-4 words/);
  bad(good.replace("/Piece ", "/The Fifth Wonder Of The World "), /must be 2-4 words/);
  const P = readJson(path.join(work, "pieces.json")), codeId = P.pieces.findIndex(p => p.k === "c") + 1;
  if (groups.some(x => x.windows.some(y => codeId >= y.from && codeId <= y.to && x.g === g.g && y.w === w.w))) bad(good.replace(/;Does thing[^\n]*/, ""), /needs a description/);
  fs.writeFileSync(f, good);
  assert.equal(cli(["check", String(g.g), String(w.w), "--work", work]).out.trim(), "OK");
});

test("merge -> describe -> build -> validate -> editor, end to end", () => {
  const { dir, cwd, work, groups } = pipeline();
  let r = cli(["apply-merge", "--work", work]); assert.equal(r.code, 0, r.out); assert.match(r.out, /^OK/);
  fakeDescriptions(work, groups);
  for (const g of groups) assert.equal(cli(["check-desc", String(g.g), "--work", work]).out.trim(), "OK");
  assert.equal(cli(["reshape-count", "--work", work]).stdout.includes('"count":0'), true);
  const json = path.join(cwd, "whitebox.json");
  r = cli(["build", "--work", work, "--out", json]); assert.equal(r.code, 0, r.out);
  const T = readJson(json);
  assert.ok(fs.existsSync(T.root), "root points at the analysed project");
  let leaves = 0, code = 0;
  (function w(n) { if (n.children) n.children.forEach(w); else { leaves++; if (n.kind === "code") { code++; assert.ok(n.description); assert.ok(["go", "py"].includes(n.lang)); } assert.equal(typeof n.text, "string"); } })(T.tree);
  assert.ok(leaves >= 20 && code >= 4, `leaves ${leaves}, code ${code}`);
  assert.ok(fs.existsSync(path.join(cwd, "whitebox.paths")));
  r = validate([json]); assert.equal(r.code, 0, r.out);
  // leaf text really is the source text (validator checks it; spot check one here)
  const leaf = (function f(n) { return n.children ? n.children.map(f).find(Boolean) : n; })(T.tree);
  const L = fs.readFileSync(path.join(T.root, leaf.file), "utf8").split("\n");
  assert.equal(L.slice(leaf.start - 1, leaf.end).join("\n"), leaf.text);
  // editor
  const html = path.join(cwd, "whitebox.html");
  r = buildEditor([json, html]); assert.equal(r.code, 0, r.out);
  const page = fs.readFileSync(html, "utf8");
  assert.ok(!page.includes("__TREE__") && !page.includes("__APPLY_CMD__"));
  assert.match(page, /apply-edits\.mjs whitebox-edits\.json/);
  const script = page.match(/<script>\n"use strict";[\s\S]*?<\/script>/)[0].replace(/^<script>|<\/script>$/g, "");
  assert.doesNotThrow(() => new vm.Script(script), "editor script must compile");
});

test("validator catches a leaf whose text no longer matches the file", () => {
  const { cwd, work, groups } = pipeline();
  cli(["apply-merge", "--work", work]); fakeDescriptions(work, groups);
  const json = path.join(cwd, "w.json"); cli(["build", "--work", work, "--out", json]);
  const T = readJson(json);
  const leaf = (function f(n) { return n.children ? n.children.map(f).find(Boolean) : n; })(T.tree);
  leaf.text += " tampered"; fs.writeFileSync(json, JSON.stringify(T));
  const r = validate([json]);
  assert.equal(r.code, 1); assert.match(r.out, /text differs/);
});

test("apply-merge refuses to discard applied reshape results unless --force", () => {
  const { work } = pipeline();
  assert.equal(cli(["apply-merge", "--work", work]).code, 0);
  fs.writeFileSync(path.join(work, "reshape.applied"), "1");
  const r = cli(["apply-merge", "--work", work]);
  assert.equal(r.code, 1); assert.match(r.out, /already applied/);
  assert.equal(cli(["apply-merge", "--work", work, "--force"]).code, 0);
});

test("merge validation: missing mapping and wrong number of top-level branches are rejected", () => {
  const { work } = pipeline();
  const lines = fs.readFileSync(path.join(work, "merge.txt"), "utf8").trim().split("\n");
  fs.writeFileSync(path.join(work, "merge.txt"), lines.slice(1).join("\n") + "\n");
  let r = cli(["apply-merge", "--work", work]); assert.equal(r.code, 1); assert.match(r.out, /missing mapping/);
  fs.writeFileSync(path.join(work, "merge.txt"), lines.map(l => l.replace(/;[^;]*$/, ";Everything Together")).join("\n") + "\n");
  r = cli(["apply-merge", "--work", work]); assert.equal(r.code, 1); assert.match(r.out, /top-level branches/);
});

test("build refuses when the source changed after the split, unless --allow-stale", () => {
  const { dir, cwd, work, groups } = pipeline();
  cli(["apply-merge", "--work", work]); fakeDescriptions(work, groups);
  const f = path.join(dir, "docs/topic1.md");
  fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("First rule of topic 1", "First rule, rewritten after the split"));
  const json = path.join(cwd, "stale.json");
  let r = cli(["build", "--work", work, "--out", json]);
  assert.equal(r.code, 1); assert.match(r.out, /changed since the split/); assert.match(r.out, /docs\/topic1\.md/);
  assert.ok(!fs.existsSync(json), "nothing is written");
  r = cli(["build", "--work", work, "--out", json, "--allow-stale"]);
  assert.equal(r.code, 0, r.out);
});

test("the cost estimate scales with agents and is printed after split", () => {
  const { work } = pipeline();
  const E = readJson(path.join(work, "estimate.json"));
  assert.ok(E.agents >= E.windows && E.tokensM > 0 && E.minutes > 0);
  assert.equal(E.tokensM, Math.floor((E.agents * 6 + 5) / 10) / 10);
  assert.match(cli(["estimate", "--work", work]).out, /estimate: ~\d+ haiku agents/);
});
