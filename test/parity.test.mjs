// Differential tests: every port (WHITEBOX_PARITY=sh,ps) must behave exactly like the Node reference on the same input:
// same printed messages and exit codes, same work files, same whitebox.json, same editor page, same bytes written back.
// Without WHITEBOX_PARITY only the reference sanity checks run. See docs/porting.md.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { cli, applyEdits, validate, buildEditor, project, tmp, readJson, fakeAgents, fakeDescriptions, sampleProject, IMPL } from "./helpers.mjs";
import { randomProject, rng } from "./stress.mjs";

const TARGETS = (process.env.WHITEBOX_PARITY || "").split(",").filter(Boolean);
const SEEDS = Number(process.env.WHITEBOX_PARITY_SEEDS || 6);

/* ---------- reference sanity (always) ---------- */
test("reference: random projects split into ordered, non-overlapping pieces that start and end on content", { skip: IMPL !== "node" }, () => {
  for (let seed = 1; seed <= 12; seed++) {
    const dir = project(randomProject(seed, 10)), work = path.join(tmp(), "w");
    const r = cli(["split", dir, "--work", work]); assert.equal(r.code, 0, `seed ${seed}: ${r.out}`);
    const P = readJson(path.join(work, "pieces.json"));
    const last = new Map();
    for (const p of P.pieces) {
      const L = fs.readFileSync(path.join(dir, P.files[p.f].rel), "utf8").replace(/\r\n/g, "\n").split("\n");
      assert.ok(p.s <= p.e && p.s > (last.get(p.f) || 0), `seed ${seed}: overlap/order in ${P.files[p.f].rel} at ${p.s}`);
      assert.ok(L[p.s - 1].trim() && L[p.e - 1].trim(), `seed ${seed}: piece ${p.i} starts or ends on a blank line`);
      last.set(p.f, p.e);
    }
  }
});

if (!TARGETS.length) {
  test("parity vs ports (skipped: set WHITEBOX_PARITY=sh and/or ps)", { skip: true }, () => {});
} else for (const T of TARGETS) suite(T);

/* ---------- helpers ---------- */
const cp = (a, b) => fs.cpSync(a, b, { recursive: true });
const maybeCopy = (a, b) => { if (fs.existsSync(a)) cp(a, b); };
const eq = (a, b, what) => assert.deepStrictEqual(a, b, what);
const text = f => fs.readFileSync(f, "utf8");
/** printed commands name the launcher and the script and contain absolute paths of this run: normalise those, nothing else */
const norm = (t, ctx, who) => {
  let x = t.replace(/\r\n/g, "\n");
  if (who === "B") x = x.split(ctx.cwdB).join(ctx.cwdA);
  return x.replace(/\b(?:node|sh|bash|dash|pwsh|powershell)\b(?: -[A-Za-z]+(?: (?!\/)[A-Za-z]+)?)* (\S*whitebox)\.(?:mjs|sh|ps1)/g, "RUN $1.X").replace(/whitebox\.(?:mjs|sh|ps1)/g, "whitebox.X");
};
function both(args, ctx, label) {
  const a = cli(args, { cwd: ctx.cwdA }), b = cli(args, { cwd: ctx.cwdB, impl: ctx.T });
  assert.equal(b.code, a.code, `${label}: exit code (node ${a.code}, ${ctx.T} ${b.code})\n--- node:\n${a.out.slice(0, 600)}\n--- ${ctx.T}:\n${b.out.slice(0, 600)}`);
  assert.equal(norm(b.stdout, ctx, "B"), norm(a.stdout, ctx, "A"), `${label}: stdout differs`);
  assert.equal(norm(b.out, ctx, "B"), norm(a.out, ctx, "A"), `${label}: output differs`);
  return a;
}
const mask = html => html.replace(/`[^`\n]*apply-edits\.(mjs|sh|ps1)[^`\n]*`/g, "`APPLY`").replace(/(node|sh|bash|dash|pwsh|powershell)[^\n"'`]*apply-edits\.(mjs|sh|ps1)/g, "APPLY");
const embedded = html => { const m = html.match(/<script type="application\/json" id="tree-src">([\s\S]*?)<\/script>/); return [JSON.parse(m[1]), html.replace(m[1], "TREE")]; };

function fullParity(T, files, label) {
  const dir = project(files, { ignore: "ignored.md\n" }), ctx = { T, cwdA: tmp("wb-a-"), cwdB: tmp("wb-b-") };
  ctx.cwdA = fs.realpathSync(ctx.cwdA); ctx.cwdB = fs.realpathSync(ctx.cwdB);
  const wA = path.join(ctx.cwdA, "w"), wB = path.join(ctx.cwdB, "w");
  both(["split", dir, "--work", "w"], ctx, `${label} split`);
  for (const f of ["pieces.json", "groups.json", "estimate.json", "selection.json"]) if (fs.existsSync(path.join(wA, f)) || fs.existsSync(path.join(wB, f))) eq(readJson(path.join(wB, f)), readJson(path.join(wA, f)), `${label}: ${f}`);
  const groups = readJson(path.join(wA, "groups.json"));
  both(["groups-args", "--work", "w"], ctx, `${label} groups-args`);
  both(["estimate", "--work", "w"], ctx, `${label} estimate`);
  // prompts the agents will see
  for (const g of groups) for (const w of g.windows) both(["window", String(g.g), String(w.w), "--work", "w"], ctx, `${label} window ${g.g}/${w.w} (before outputs)`);
  // stand-in agents write outputs in A; B gets the same files
  fakeAgents(wA); cp(path.join(wA, "out"), path.join(wB, "out")); fs.copyFileSync(path.join(wA, "merge.txt"), path.join(wB, "merge.txt"));
  both(["status", "--work", "w"], ctx, `${label} status`);
  both(["check-all", "--work", "w"], ctx, `${label} check-all`);
  for (const g of groups) for (const w of g.windows) { both(["window", String(g.g), String(w.w), "--work", "w"], ctx, `${label} window ${g.g}/${w.w}`); both(["check", String(g.g), String(w.w), "--work", "w"], ctx, `${label} check ${g.g}/${w.w}`); }
  both(["merge-input", "--work", "w"], ctx, `${label} merge-input`);
  both(["apply-merge", "--work", "w"], ctx, `${label} apply-merge`);
  assert.equal(text(path.join(wB, "tree.paths")), text(path.join(wA, "tree.paths")), `${label}: tree.paths`);
  eq(readJson(path.join(wB, "leafdesc.json")), readJson(path.join(wA, "leafdesc.json")), `${label}: leafdesc.json`);
  for (const g of groups) both(["describe-input", String(g.g), "--work", "w"], ctx, `${label} describe-input ${g.g}`);
  fakeDescriptions(wA, groups); cp(path.join(wA, "desc"), path.join(wB, "desc"));
  for (const g of groups) both(["check-desc", String(g.g), "--work", "w"], ctx, `${label} check-desc ${g.g}`);
  // reshape wide branches
  const count = both(["reshape-count", "--work", "w"], ctx, `${label} reshape-count`);
  const list = both(["reshape-list", "--work", "w"], ctx, `${label} reshape-list`);
  eq(readJson(path.join(wB, "wide.json")), readJson(path.join(wA, "wide.json")), `${label}: wide.json`);
  const wide = readJson(path.join(wA, "wide.json"));
  fs.mkdirSync(path.join(wA, "reshape"), { recursive: true }); fs.mkdirSync(path.join(wB, "reshape"), { recursive: true });
  wide.forEach((_, i) => {
    const n = String(i + 1), inp = both(["reshape-input", n, "--work", "w"], ctx, `${label} reshape-input ${n}`).stdout;
    const kids = inp.split("\n").slice(inp.split("\n").findIndex(l => l.startsWith("CHILDREN of")) + 1).filter(Boolean).map(l => l.split("   ")[0]);
    const lines = kids.map((c, k) => `${c};Theme ${Math.floor(k / 4) + 1};Describes theme ${Math.floor(k / 4) + 1}.`);
    fs.writeFileSync(path.join(wA, "reshape", `r${n}.txt`), lines.join("\n") + "\n"); fs.writeFileSync(path.join(wB, "reshape", `r${n}.txt`), lines.join("\n") + "\n");
    both(["check-reshape", n, "--work", "w"], ctx, `${label} check-reshape ${n}`);
  });
  if (wide.length) {
    both(["apply-reshape", "--work", "w"], ctx, `${label} apply-reshape`);
    assert.equal(text(path.join(wB, "tree.paths")), text(path.join(wA, "tree.paths")), `${label}: tree.paths after reshape`);
    assert.equal(text(path.join(wB, "desc", "_all.txt")), text(path.join(wA, "desc", "_all.txt")), `${label}: desc/_all.txt`);
    both(["apply-merge", "--work", "w"], ctx, `${label} apply-merge guard after reshape`);
  }
  both(["reshape-count", "--work", "w"], ctx, `${label} reshape-count after`);
  // build, validate, editor
  const jA = path.join(ctx.cwdA, "whitebox.json"), jB = path.join(ctx.cwdB, "whitebox.json");
  both(["build", "--work", "w", "--out", "whitebox.json"], ctx, `${label} build`);
  eq(readJson(jB), readJson(jA), `${label}: whitebox.json`);
  assert.equal(text(path.join(ctx.cwdB, "whitebox.paths")), text(path.join(ctx.cwdA, "whitebox.paths")), `${label}: whitebox.paths`);
  const vA = validate([jA], { cwd: ctx.cwdA }), vB = validate([jB], { cwd: ctx.cwdB, impl: T });
  assert.equal(vB.code, vA.code, `${label}: validate exit`); assert.equal(vB.out, vA.out.replace(new RegExp(ctx.cwdA, "g"), ctx.cwdB), `${label}: validate output`);
  const hA = path.join(ctx.cwdA, "e.html"), hB = path.join(ctx.cwdB, "e.html");
  assert.equal(buildEditor([jA, hA], { cwd: ctx.cwdA }).code, 0); assert.equal(buildEditor([jB, hB], { cwd: ctx.cwdB, impl: T }).code, 0);
  const [tA, restA] = embedded(mask(text(hA))), [tB, restB] = embedded(mask(text(hB)));
  eq(tB, tA, `${label}: embedded tree`); assert.equal(restB, restA, `${label}: editor page outside the tree`);
  assert.ok(!text(hA).includes("</script><"), "sanity");
  // stale source
  const first = Object.keys(files).find(f => /\.(md|go|py|js)$/.test(f)); const old = fs.readFileSync(path.join(dir, first), "utf8");
  fs.appendFileSync(path.join(dir, first), "\nchanged after split\n");
  both(["build", "--work", "w", "--out", "stale.json"], ctx, `${label} build on stale source`);
  fs.writeFileSync(path.join(dir, first), old);
  return { dir, ctx, treeA: readJson(jA) };
}

function editsFor(tree, seed, dir) {
  const r = rng(seed), leaves = []; (function w(n) { n.children ? n.children.forEach(w) : leaves.push(n); })(tree.tree);
  const docs = leaves.filter(l => l.kind !== "code"), code = leaves.filter(l => l.kind === "code");
  const edits = [], excluded = [], intents = [], taken = new Set();
  const free = l => { for (const f of leaves.filter(x => x.file === l.file)) if (!(f.end < l.start || f.start > l.end) && taken.has(f.start + ":" + f.file)) return false; return true; };
  const take = l => { taken.add(l.start + ":" + l.file); return l; };
  for (const l of docs) { const x = r(); if (!free(l)) continue; if (x < 0.25) edits.push({ file: l.file, start: l.start, end: l.end, before: l.text, after: l.text.split("\n")[0] + "\nEDITED é ✔ — line\n\nand a blank", path: l.title }), take(l); else if (x < 0.35) excluded.push({ file: l.file, start: l.start, end: l.end, before: l.text, path: l.title }), take(l); }
  for (const l of code.slice(0, 6)) { if (r() < 0.5) excluded.push({ file: l.file, start: l.start, end: l.end, before: l.text, path: l.title, kind: "code" }); else intents.push({ file: l.file, start: l.start, end: l.end, path: l.title, before: "a", after: "b" }); }
  return { version: 1, root: dir, edits, excluded, intents };
}

function applyParity(T, files, label) {
  const { dir, ctx, treeA } = fullParity(T, files, label);
  const dA = tmp("wb-pa-"), dB = tmp("wb-pb-"); cp(dir, dA); cp(dir, dB);
  const edits = editsFor(treeA, 99, dir), eA = path.join(ctx.cwdA, "edits.json"), eB = path.join(ctx.cwdB, "edits.json");
  fs.writeFileSync(eA, JSON.stringify(edits, null, 2)); fs.writeFileSync(eB, JSON.stringify(edits, null, 2));
  const run = (args, who) => who === "A" ? applyEdits([eA, ...args, "--root", dA], { cwd: ctx.cwdA }) : applyEdits([eB, ...args, "--root", dB], { cwd: ctx.cwdB, impl: T });
  const same = (args, what) => { const a = run(args, "A"), b = run(args, "B"); assert.equal(b.code, a.code, `${label} apply ${what}: exit`); assert.equal(b.out.replace(dB, dA), a.out, `${label} apply ${what}: output`); return a; };
  const snap = d => Object.fromEntries(fs.readdirSync(d, { recursive: true }).filter(f => fs.statSync(path.join(d, f)).isFile() && !f.startsWith(".git")).map(f => [f, fs.readFileSync(path.join(d, f))]));
  same(["--dry-run"], "dry-run"); eq(snap(dB), snap(dA), `${label}: dry run leaves files untouched`);
  same([], "plain"); eq(snap(dB), snap(dA), `${label}: files after plain apply (byte for byte)`);
  fs.cpSync(dir, dA, { recursive: true }); fs.cpSync(dir, dB, { recursive: true });
  same(["--drop-excluded"], "drop-excluded"); eq(snap(dB), snap(dA), `${label}: files after --drop-excluded`);
  same(["--drop-excluded"], "second apply (conflicts)"); eq(snap(dB), snap(dA), `${label}: files after conflicting re-apply`);
}

function suite(T) {
  test(`[${T}] sample project: split, prompts, checks, merge, describe, reshape, build, validate, editor`, () => { fullParity(T, Object.fromEntries(Object.entries(readSample()).map(([k, v]) => [k, v])), "sample"); });
  test(`[${T}] file selection report matches on a project with every skip reason`, () => {
    const dir = project(selectionFiles(), { ignore: "ignored.md\n" }), ctx = { T, cwdA: tmp("wb-a-"), cwdB: tmp("wb-b-") };
    for (const extra of [[], ["--tests", "--config"], ["--exclude", "docs/**"], ["--include", "deploy.pem"], ["--max-kb", "1000"]]) {
      both(["split", dir, "--work", "w", ...extra], ctx, `selection ${extra.join(" ") || "default"}`);
      eq(readJson(path.join(ctx.cwdB, "w", "selection.json")), readJson(path.join(ctx.cwdA, "w", "selection.json")), `selection.json ${extra.join(" ")}`);
      eq(readJson(path.join(ctx.cwdB, "w", "pieces.json")), readJson(path.join(ctx.cwdA, "w", "pieces.json")), `pieces.json ${extra.join(" ")}`);
    }
  });
  for (let seed = 1; seed <= SEEDS; seed++) test(`[${T}] random project, seed ${seed}: full pipeline, write-back, byte-identical`, () => { applyParity(T, randomProject(seed, 12), `seed ${seed}`); });
  test(`[${T}] check and validate reject the same malformed agent output with the same messages`, () => {
    const dir = project(randomProject(3, 12)), ctx = { T, cwdA: tmp("wb-a-"), cwdB: tmp("wb-b-") }, wA = path.join(ctx.cwdA, "w"), wB = path.join(ctx.cwdB, "w");
    both(["split", dir, "--work", "w"], ctx, "split"); fakeAgents(wA); cp(path.join(wA, "out"), path.join(wB, "out"));
    const g = readJson(path.join(wA, "groups.json"))[0], w = g.windows[0], f = `out/g${g.g}-w${w.w}.txt`, good = text(path.join(wA, f)), lines = good.trim().split("\n");
    const variants = [lines.slice(1).join("\n") + "\n", [lines[0], ...lines].join("\n") + "\n", good.replace(/Piece (\d+)/, "Piece"), good.replace("/Piece ", "/The Fifth Wonder Of The World "), good.replace(/;/, ":"), "garbage\n", good.replace(/\n/g, "\r\n"), good + "99999;Area One/Topic Two/Piece Nine\n"];
    for (const [i, v] of variants.entries()) { fs.writeFileSync(path.join(wA, f), v); fs.writeFileSync(path.join(wB, f), v); both(["check", String(g.g), String(w.w), "--work", "w"], ctx, `check variant ${i}`); }
    fs.rmSync(path.join(wB, `out/g${g.g}-w${w.w}.sum`)); fs.rmSync(path.join(wA, `out/g${g.g}-w${w.w}.sum`)); both(["check", String(g.g), String(w.w), "--work", "w"], ctx, "check without summary");
  });
}

/* fixtures shared with the other suites */
function readSample() { const dir = sampleProject(); const out = {}; (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { if (e.name === ".git") continue; const p = path.join(d, e.name); e.isDirectory() ? walk(p) : (out[path.relative(dir, p)] = fs.readFileSync(p, "utf8")); } })(dir); delete out[".gitignore"]; return out; }
function selectionFiles() { return { "README.md": "# Hello\n\nWorld text here.\n", "docs/guide.md": "# Guide\n\nUse it.\n", "src/app.go": "package app\n\nfunc Run() {}\n", "src/app_test.go": "package app\n\nfunc TestRun() {}\n", "src/gen.pb.go": "// Code generated by protoc. DO NOT EDIT.\npackage app\n\nfunc G() {}\n", "src/web/index.ts": "export const a = 1;\n", "src/web/index.test.ts": "test('x', () => {});\n", "node_modules/lib/index.js": "module.exports = 1;\n", "dist/bundle.js": "var a=1;\n", "static/app.min.js": "var a=1;\n", "go.sum": "abc h1:xyz\n", "package-lock.json": "{}\n", "deploy.pem": "-----BEGIN KEY-----\n", "id_rsa": "private\n", "prod.tfvars": "pw = 1\n", ".env": "TOKEN=abc\n", ".hidden/notes.md": "# secret notes\n\ntext\n", "config/app.yaml": "a: 1\n", "testdata/golden.md": "# golden\n\nfixture\n", "image.png": "PNG\u0000\u0000binary", "ignored.md": "# ignored by git\n\ntext\n", "blob.go": "package x\n\n// " + "x".repeat(400 * 1024) + "\n", "with space/ünï.md": "# Sp\n\ntext é\n", "a/b/c.sh": "f() {\n  echo hi\n}\n", "schema.sql": "CREATE TABLE t (a TEXT);\n" }; }
