// "Never write into the project": nothing is created in the analysed directory or the current directory unless the caller names a place,
// and the editor page can be built as an Artifact fragment. Runs against every implementation (WHITEBOX_IMPL).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { cli, buildEditor, validate, sampleProject, tmp, readJson, fakeAgents, fakeDescriptions, SCRIPTS } from "./helpers.mjs";

const files = d => fs.readdirSync(d, { recursive: true }).map(String).filter(f => !f.startsWith(".git") && fs.statSync(path.join(d, f)).isFile()).sort();
const scriptOf = html => { const m = html.match(/<script>\n"use strict";[\s\S]*?<\/script>/); return m && m[0].replace(/^<script>|<\/script>$/g, ""); };

test("without --work every command stops with one clear error and creates nothing", () => {
  const cwd = tmp("wb-cwd-"), dir = sampleProject(), before = files(dir);
  for (const args of [["split", dir], ["status"], ["window", "1", "1"], ["groups-args"], ["build"], ["estimate"]]) {
    const r = cli(args, { cwd });
    assert.equal(r.code, 1, args.join(" "));
    assert.match(r.out, /--work DIR is required.*scratch directory outside the project/);
  }
  assert.deepEqual(fs.readdirSync(cwd), [], "the current directory stays empty");
  assert.deepEqual(files(dir), before, "the project stays untouched");
  assert.match(cli(["bogus"], { cwd }).out, /unknown command bogus/, "an unknown command is reported first");
});

test("a whole run leaves the analysed project and the current directory exactly as they were", () => {
  const cwd = tmp("wb-cwd-"), scratch = tmp("wb-scratch-"), dir = sampleProject(), before = files(dir);
  const work = path.join(scratch, "w");
  assert.equal(cli(["split", dir, "--work", work], { cwd }).code, 0);
  fakeAgents(work); assert.equal(cli(["apply-merge", "--work", work], { cwd }).code, 0);
  const groups = readJson(path.join(work, "groups.json")); fakeDescriptions(work, groups);
  const b = cli(["build", "--work", work], { cwd });          // no --out: the default lives inside the work directory
  assert.equal(b.code, 0, b.out);
  assert.ok(fs.existsSync(path.join(work, "whitebox.json")) && fs.existsSync(path.join(work, "whitebox.paths")), "outputs default to the work directory");
  const html = path.join(scratch, "page.html");
  assert.equal(buildEditor([path.join(work, "whitebox.json"), html, "--artifact", "--title", "Sample Whitebox"], { cwd }).code, 0);
  assert.equal(validate([path.join(work, "whitebox.json")], { cwd }).code, 0);
  assert.deepEqual(fs.readdirSync(cwd), [], "nothing in the current directory");
  assert.deepEqual(files(dir), before, "nothing in the project");
});

test("build-editor needs both file arguments and never picks a default output", () => {
  const cwd = tmp("wb-cwd-"), r = buildEditor(["only-one-arg.json"], { cwd });
  assert.equal(r.code, 2); assert.match(r.out, /usage: build-editor <whitebox\.json> <out\.html>/);
  assert.deepEqual(fs.readdirSync(cwd), []);
});

test("--artifact writes a page fragment for the Artifact tool; the default is a full document", () => {
  const scratch = tmp("wb-scratch-"), json = path.join(scratch, "t.json");
  fs.writeFileSync(json, JSON.stringify({ version: 1, root: "x", title: "T", tree: { id: "n0", title: "T", children: [{ id: "n1", title: "A </script> Piece", file: "a.md", start: 1, end: 1, text: "hello" }] } }));
  const full = path.join(scratch, "full.html"), frag = path.join(scratch, "frag.html");
  assert.equal(buildEditor([json, full], { cwd: scratch }).code, 0);
  assert.equal(buildEditor([json, frag, "--artifact", "--title", "My <Proj> & Whitebox"], { cwd: scratch }).code, 0);
  const F = fs.readFileSync(full, "utf8"), A = fs.readFileSync(frag, "utf8");
  assert.ok(F.startsWith("<!doctype html>") && F.includes("<body>") && F.includes("<title>Whitebox</title>"), "default: complete document");
  assert.ok(A.startsWith("<title>My &lt;Proj&gt; &amp; Whitebox</title>"), "artifact: <title> first, escaped");
  for (const w of ["<!doctype", "<html", "<head>", "</head>", "<body>", "</body>", "</html>", "<meta charset", 'name="viewport"']) assert.ok(!A.includes(w), `artifact fragment must not contain ${w}`);
  for (const page of [F, A]) {
    assert.ok(!page.includes("__TREE__") && !page.includes("__APPLY_CMD__"));
    assert.ok(page.includes("A \\u003c/script> Piece"), "the tree is embedded with < escaped, so it cannot close the script element");
    assert.doesNotThrow(() => new vm.Script(scriptOf(page)), "editor script compiles");
  }
});

test("the editor page follows the artifact contract: both dark-theme selectors, downloads and send-to-Claude through capabilities", () => {
  const t = fs.readFileSync(path.join(SCRIPTS, "editor.template.html"), "utf8");
  assert.ok(/@media \(prefers-color-scheme:dark\)\{:root:not\(\[data-theme=light\]\)/.test(t) && t.includes(":root[data-theme=dark]{"), "dark tokens under the media query and under [data-theme=dark]");
  assert.ok(t.includes('claude.use(n)') && t.includes('cap("downloads")') && t.includes('whitebox-edits/'), "uses the downloads and db capabilities");
  assert.ok(!/<a[^>]*download=/.test(t), "no inline download links (a sandboxed page cannot start downloads itself)");
  assert.ok(!/https?:\/\/(?!www\.w3\.org\/)[a-z]/i.test(t), "no external resources (the SVG namespace URL is an identifier, not a load)");
});
