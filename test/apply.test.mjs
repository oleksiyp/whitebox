import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { cli, run, SCRIPTS, sampleProject, tmp, readJson, fakeAgents, fakeDescriptions } from "./helpers.mjs";

const APPLY = path.join(SCRIPTS, "apply-edits.mjs");
function built() {
  const dir = sampleProject(), cwd = tmp("wb-out-"), work = path.join(cwd, "w");
  cli(["split", dir, "--work", work]); fakeAgents(work); cli(["apply-merge", "--work", work]);
  fakeDescriptions(work, readJson(path.join(work, "groups.json")));
  const json = path.join(cwd, "whitebox.json"); cli(["build", "--work", work, "--out", json]);
  const leaves = []; (function w(n) { n.children ? n.children.forEach(w) : leaves.push(n); })(readJson(json).tree);
  return { dir, cwd, leaves };
}
const snapshot = dir => Object.fromEntries(fs.readdirSync(dir, { recursive: true, withFileTypes: true }).filter(e => e.isFile() && !String(e.parentPath || e.path).includes(".git")).map(e => { const p = path.join(e.parentPath || e.path, e.name); return [p, fs.readFileSync(p, "utf8")]; }));
const edit = (l, after) => ({ file: l.file, start: l.start, end: l.end, before: l.text, after, path: l.title });

test("applies markdown edits, ignores code pieces, never touches source code", () => {
  const { dir, cwd, leaves } = built();
  const doc = leaves.find(l => l.file === "docs/topic1.md" && l.text.includes("First rule"));
  const doc2 = leaves.find(l => l.file === "docs/topic2.md" && l.text.includes("Second rule"));
  const code = leaves.find(l => l.kind === "code" && l.file === "src/server.go");
  const before = snapshot(dir);
  const edits = { version: 1, root: dir, edits: [edit(doc, "- [R-101] First rule, EDITED.\n- [R-102] A brand new second line.")],
    excluded: [{ file: doc2.file, start: doc2.start, end: doc2.end, before: doc2.text }, { file: code.file, start: code.start, end: code.end, before: code.text, kind: "code" }],
    intents: [{ file: code.file, start: code.start, end: code.end, before: "a", after: "b" }] };
  const ef = path.join(cwd, "edits.json"); fs.writeFileSync(ef, JSON.stringify(edits));
  let r = run(APPLY, [ef, "--drop-excluded", "--dry-run"]);
  assert.equal(r.code, 0, r.out); assert.deepEqual(snapshot(dir), before, "dry run changes nothing");
  assert.match(r.out, /never rewritten or deleted/);
  r = run(APPLY, [ef, "--drop-excluded"]); assert.equal(r.code, 0, r.out);
  const after = snapshot(dir);
  const changed = Object.keys(after).filter(f => after[f] !== before[f]).map(f => path.relative(dir, f)).sort();
  assert.deepEqual(changed, ["docs/topic1.md", "docs/topic2.md"], "only the two markdown files change");
  assert.ok(after[path.join(dir, "docs/topic1.md")].includes("First rule, EDITED.") && after[path.join(dir, "docs/topic1.md")].includes("brand new second line"));
  assert.ok(!after[path.join(dir, "docs/topic2.md")].includes("Second rule"), "excluded markdown piece removed");
  assert.equal(after[path.join(dir, "src/server.go")], before[path.join(dir, "src/server.go")], "Go file byte-identical");
});

test("a second apply of the same export reports conflicts and changes nothing", () => {
  const { dir, cwd, leaves } = built();
  const doc = leaves.find(l => l.file === "docs/topic3.md" && l.text.includes("First rule"));
  const ef = path.join(cwd, "edits.json");
  fs.writeFileSync(ef, JSON.stringify({ version: 1, root: dir, edits: [edit(doc, "- changed once")], excluded: [], intents: [] }));
  assert.equal(run(APPLY, [ef]).code, 0);
  const afterFirst = snapshot(dir);
  const r = run(APPLY, [ef]);
  assert.equal(r.code, 1); assert.match(r.out, /CONFLICT/);
  assert.deepEqual(snapshot(dir), afterFirst);
});

test("several edits in one file land correctly regardless of order and line shifts", () => {
  const { dir, cwd, leaves } = built();
  const a = leaves.find(l => l.file === "docs/topic4.md" && l.text.includes("Intro paragraph"));
  const b = leaves.find(l => l.file === "docs/topic4.md" && l.text.includes("Second rule"));
  const ef = path.join(cwd, "edits.json");
  fs.writeFileSync(ef, JSON.stringify({ version: 1, root: dir, edits: [edit(a, "Intro one.\n\nIntro two.\n\nIntro three."), edit(b, "- only bullet")], excluded: [], intents: [] }));
  assert.equal(run(APPLY, [ef]).code, 0);
  const txt = fs.readFileSync(path.join(dir, "docs/topic4.md"), "utf8");
  assert.ok(txt.includes("Intro three.") && txt.includes("- only bullet") && !txt.includes("Second rule"));
  assert.ok(txt.indexOf("Intro three.") < txt.indexOf("- only bullet"));
});

test("CRLF files keep their line endings", () => {
  const { dir, cwd, leaves } = built();
  const f = path.join(dir, "docs/topic5.md");
  const doc = leaves.find(l => l.file === "docs/topic5.md" && l.text.includes("First rule"));
  fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace(/\n/g, "\r\n"));
  const ef = path.join(cwd, "edits.json");
  fs.writeFileSync(ef, JSON.stringify({ version: 1, root: dir, edits: [edit(doc, "- changed\n- two lines")], excluded: [], intents: [] }));
  assert.equal(run(APPLY, [ef]).code, 0);
  const txt = fs.readFileSync(f, "utf8");
  assert.ok(txt.includes("- changed\r\n- two lines\r\n") && !/[^\r]\n/.test(txt));
});
