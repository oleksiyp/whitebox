// Port-specific tests for the shell port (whitebox.sh and friends). They only run with WHITEBOX_IMPL=sh.
// The generic suite and test/parity.test.mjs cover behaviour; these cover what is special about running sh + awk.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { cli, buildEditor, sampleProject, tmp, readJson, fakeAgents, fakeDescriptions, SCRIPTS, IMPL } from "./helpers.mjs";

const skip = IMPL !== "sh";

test("sh: the editor page names the shell apply-edits tool (pipeline.test.mjs checks the .mjs spelling only)", { skip }, () => {
  const dir = sampleProject(), cwd = tmp("wb-sh-"), work = path.join(cwd, "w");
  cli(["split", dir, "--work", work]); fakeAgents(work); cli(["apply-merge", "--work", work]);
  fakeDescriptions(work, readJson(path.join(work, "groups.json")));
  const json = path.join(cwd, "whitebox.json"); cli(["build", "--work", work, "--out", json]);
  const html = path.join(cwd, "whitebox.html");
  assert.equal(buildEditor([json, html], { cwd }).code, 0);
  const page = fs.readFileSync(html, "utf8");
  assert.ok(!page.includes("__TREE__") && !page.includes("__APPLY_CMD__"));
  assert.match(page, /sh \S*apply-edits\.sh whitebox-edits\.json/);
});

test("sh: works from an install directory whose path contains spaces", { skip }, () => {
  const inst = path.join(tmp("wb-sp-"), "my tools");
  fs.cpSync(SCRIPTS, inst, { recursive: true });
  const dir = sampleProject(), cwd = tmp("wb-sh-");
  const r = spawnSync("sh", [path.join(inst, "whitebox.sh"), "split", dir, "--work", "w"], { cwd, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const w = spawnSync("sh", [path.join(inst, "whitebox.sh"), "window", "1", "1", "--work", "w"], { cwd, encoding: "utf8" });
  assert.equal(w.status, 0, w.stderr);
  assert.match(w.stdout, /"[^"\n]*my tools[^"\n]*whitebox\.sh" check 1 1/);   // quoted because it contains a space
});

test("sh: needs nothing but the base tools (runs with a PATH of exactly those, no node/python/perl/jq)", { skip }, () => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), "wb-bin-"));
  const need = "sh awk sed grep sort cut tr head tail wc cat cp mv rm mkdir mktemp od dd printf dirname ls date find test git sha1sum shasum openssl env uname".split(" ");
  for (const t of need) { const r = spawnSync("sh", ["-c", `command -v ${t}`], { encoding: "utf8" }); const p = r.stdout.trim(); if (p.startsWith("/")) fs.symlinkSync(p, path.join(bin, t)); }
  const env = { PATH: bin, TMPDIR: os.tmpdir(), HOME: os.homedir() };
  const dir = sampleProject(), cwd = tmp("wb-sh-"), work = path.join(cwd, "w");
  const run = (name, args) => spawnSync(path.join(bin, "sh"), [path.join(SCRIPTS, name), ...args], { cwd, env, encoding: "utf8" });
  let r = run("whitebox.sh", ["split", dir, "--work", work]); assert.equal(r.status, 0, r.stdout + r.stderr);
  fakeAgents(work);
  r = run("whitebox.sh", ["apply-merge", "--work", work]); assert.equal(r.status, 0, r.stdout + r.stderr);
  fakeDescriptions(work, readJson(path.join(work, "groups.json")));
  const json = path.join(cwd, "whitebox.json");
  r = run("whitebox.sh", ["build", "--work", work, "--out", json]); assert.equal(r.status, 0, r.stdout + r.stderr);
  r = run("validate.sh", [json]); assert.equal(r.status, 0, r.stdout + r.stderr);
  r = run("build-editor.sh", [json, path.join(cwd, "e.html")]); assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("sh: output does not depend on the caller's locale", { skip }, () => {
  const dir = sampleProject();
  const outs = ["C", "en_US.UTF-8", "de_DE.UTF-8"].map(l => {
    const cwd = tmp("wb-sh-");
    const r = spawnSync("sh", [path.join(SCRIPTS, "whitebox.sh"), "split", dir, "--work", "w"], { cwd, encoding: "utf8", env: { ...process.env, LC_ALL: l, LANG: l } });
    return fs.readFileSync(path.join(cwd, "w", "pieces.json"), "utf8") + r.stdout.split(cwd).join("CWD");
  });
  assert.equal(outs[1], outs[0]); assert.equal(outs[2], outs[0]);
});
