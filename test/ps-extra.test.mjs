// Port-specific checks for the PowerShell port (the shared suites cover behaviour; these cover what only a PowerShell port can get wrong).
// Static checks always run; the runtime checks need a PowerShell: set WHITEBOX_PWSH (and WHITEBOX_PREFIX for a container).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { tool, project, tmp, SCRIPTS } from "./helpers.mjs";

const files = ["whitebox.ps1", "apply-edits.ps1", "validate.ps1", "build-editor.ps1", "lib/wb-common.ps1"].map(f => path.join(SCRIPTS, f));
const HAVE_PS = !!(process.env.WHITEBOX_PWSH || process.env.WHITEBOX_IMPL === "ps");
const ps = (name, args, opts = {}) => tool(name, args, { ...opts, impl: "ps" });

test("ps sources: ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI) and no construct that 5.1 lacks or that is forbidden", () => {
  for (const f of files) {
    const t = fs.readFileSync(f);
    assert.ok(![...t].some(b => b > 127 || b === 13), `${f}: non-ASCII byte or CR`);
    const s = t.toString("latin1");
    const bad = [
      [/\?\./, "null-conditional ?."], [/\?\?/, "null-coalescing ??"], [/&&|\|\|/, "pipeline chain operators"], [/\bAdd-Type\b/, "Add-Type"],
      [/\bSet-Content\b|\bOut-File\b|\bConvertTo-Json\b|\bConvertFrom-Json\b|\bGet-Content\b/, "cmdlets with encoding/shape differences between 5.1 and 7"],
      [/-AsHashtable|-Parallel|\bIsWindows\b|::new\(/, "7-only syntax"], [/Join-Path[ \t]+\S+[ \t]+\S+[ \t]+\S+/, "Join-Path with 3+ arguments"],
    ];
    for (const [re, what] of bad) assert.ok(!re.test(s.replace(/'(?:[^'\n]|'')*'/g, "''").replace(/#[^\n]*/g, "")), `${path.basename(f)}: ${what}`);
  }
});

test("ps runtime: output has no BOM and no CR, files are written without BOM", { skip: !HAVE_PS }, () => {
  const dir = project({ "a.md": "# T\r\n\r\ntext é\r\n", "ünï/b.go": "package x\n\nfunc F() {}\n" });
  const cwd = fs.realpathSync(tmp("wb-ps-"));
  const r = ps("whitebox", ["split", dir, "--work", "w"], { cwd });
  assert.equal(r.code, 0, r.out);
  assert.ok(!r.out.includes("\r") && !r.out.startsWith("﻿"));
  for (const f of ["pieces.json", "groups.json", "estimate.json", "selection.json"]) {
    const b = fs.readFileSync(path.join(cwd, "w", f)); assert.notDeepEqual([...b.subarray(0, 3)], [0xef, 0xbb, 0xbf], `${f} has a BOM`);
    assert.ok(!b.includes(13), `${f} contains CR`);
  }
  assert.ok(JSON.parse(fs.readFileSync(path.join(cwd, "w", "pieces.json"), "utf8")).files.some(f => f.rel === "ünï/b.go"));
});

test("ps runtime: unknown command, missing arguments and usage exit codes", { skip: !HAVE_PS }, () => {
  let r = ps("whitebox", ["nope"]); assert.equal(r.code, 1); assert.equal(r.out.trim(), "unknown command nope");
  r = ps("whitebox", ["split", "--work", "w"]); assert.equal(r.code, 1); assert.match(r.out, /^usage: split/);
  r = ps("whitebox", ["split"]); assert.equal(r.code, 1); assert.match(r.out, /--work DIR is required/);
  r = ps("apply-edits", []); assert.equal(r.code, 2); assert.match(r.out, /usage: apply-edits/);
});

test("ps runtime: switches written like the Node CLI reach the script untouched (--work, --tests, --include with commas)", { skip: !HAVE_PS }, () => {
  const dir = project({ "src/app_test.go": "package a\n\nfunc T() {}\n", "x/y.md": "# H\n\ntext here\n", "z.md": "# Z\n\nzed text\n" });
  const cwd = fs.realpathSync(tmp("wb-ps-"));
  const r = ps("whitebox", ["split", dir, "--work", "w", "--tests", "--exclude", "x/**,nothing/*"], { cwd });
  assert.equal(r.code, 0, r.out); assert.match(r.out, /2 files, /);
});
