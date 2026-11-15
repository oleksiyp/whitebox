import { spawnSync, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const SCRIPTS = path.join(ROOT, "skills", "whitebox", "scripts");

// canonical path: on Windows os.tmpdir() can be an 8.3 short name (RUNNER~1) while other tools report the long one
export function tmp(prefix = "wb-") { return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), prefix))); }

/**
 * Which implementation the suite exercises (the same tests run against all of them):
 *   WHITEBOX_IMPL=node (default) | sh | ps
 *   WHITEBOX_SH     shell used for the sh port (default "sh"; try dash, bash, "busybox sh")
 *   WHITEBOX_PWSH   PowerShell executable (default "pwsh"; on Windows PowerShell 5.1 use "powershell")
 *   WHITEBOX_PREFIX command prefix, e.g. a "docker run --rm -v /tmp:/tmp -v <repo>:<repo> -w /tmp IMAGE"
 *                   so the port runs inside Linux/busybox/pwsh containers while the harness stays on the host
 */
export const IMPL = process.env.WHITEBOX_IMPL || "node";
const PREFIX = (process.env.WHITEBOX_PREFIX || "").split(/\s+/).filter(Boolean);
const SHELL = (process.env.WHITEBOX_SH || "sh").split(/\s+/).filter(Boolean);
const PWSH = (process.env.WHITEBOX_PWSH || "pwsh").split(/\s+/).filter(Boolean);
const EXT = { node: ".mjs", sh: ".sh", ps: ".ps1" };
/** argv prefix for one of the tools: whitebox | apply-edits | validate | build-editor */
export function toolCommand(name, impl = IMPL) {
  const file = path.join(SCRIPTS, name + EXT[impl]);
  const base = impl === "node" ? ["node", file] : impl === "sh" ? [...SHELL, file] : [...PWSH, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", file];
  return impl === "node" ? base : [...PREFIX, ...base];   // the prefix (containers) only applies to ports
}
/** run a tool, return {code, out, stdout}; never throws */
export function tool(name, args, opts = {}) {
  const [cmd, ...pre] = toolCommand(name, opts.impl);
  const r = spawnSync(cmd, [...pre, ...args], { encoding: "utf8", cwd: opts.cwd, maxBuffer: 1 << 28, env: { ...process.env, ...(opts.env || {}) } });
  return { code: r.status, out: (r.stdout || "") + (r.stderr || ""), stdout: r.stdout || "" };
}
export const cli = (args, opts) => tool("whitebox", args, opts);
export const applyEdits = (args, opts) => tool("apply-edits", args, opts);
export const validate = (args, opts) => tool("validate", args, opts);
export const buildEditor = (args, opts) => tool("build-editor", args, opts);

/** create a git project from {relpath: content}; returns its directory */
export function project(files, { git = true, ignore = "" } = {}) {
  const dir = tmp("wb-proj-");
  for (const [rel, content] of Object.entries(files)) {
    const p = path.join(dir, rel); fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, content);
  }
  if (ignore) fs.writeFileSync(path.join(dir, ".gitignore"), ignore);
  if (git) { execFileSync("git", ["init", "-q"], { cwd: dir }); }
  return dir;
}

export const readJson = p => JSON.parse(fs.readFileSync(p, "utf8"));

/**
 * A stand-in for the Haiku agents: writes deterministic window outputs, merge file and descriptions
 * so that the whole pipeline (check -> apply-merge -> check-desc -> build) runs without an LLM.
 */
export function fakeAgents(work) {
  const pieces = readJson(path.join(work, "pieces.json")), groups = readJson(path.join(work, "groups.json"));
  const words = s => s.replace(/[^A-Za-z0-9]+/g, " ").trim().split(/\s+/).slice(0, 2).map(w => w[0].toUpperCase() + w.slice(1)).join(" ");
  for (const g of groups) {
    let sum = "";
    for (const w of g.windows) {
      const lines = [];
      for (let i = w.from; i <= w.to; i++) {
        const p = pieces.pieces[i - 1], stem = words(path.basename(pieces.files[p.f].rel, path.extname(pieces.files[p.f].rel))) || "Misc";
        const topic = stem.split(" ").length < 2 ? `${stem} Topic` : stem;
        lines.push(`${i};Area ${g.g}/${topic}/Piece ${i}${p.k === "c" ? `;Does thing number ${i} for the system.` : ""}`);
      }
      fs.writeFileSync(path.join(work, "out", `g${g.g}-w${w.w}.txt`), lines.join("\n") + "\n");
      fs.writeFileSync(path.join(work, "out", `g${g.g}-w${w.w}.sum`), `Group ${g.g} window ${w.w} summary.\n`);
    }
  }
  fs.writeFileSync(path.join(work, "merge.txt"), groups.map(g => `${g.g};Area ${g.g};Area ${g.g}`).join("\n") + "\n");
}
export function fakeDescriptions(work, groups) {
  const rows = fs.readFileSync(path.join(work, "tree.paths"), "utf8").split("\n").filter(Boolean).map(l => l.split(";"));
  for (const g of groups) {
    const need = new Set();
    for (const [gg, p] of rows) if (+gg === g.g) { const s = p.split("/"); for (let d = 1; d < s.length && d <= 3; d++) need.add(s.slice(0, d).join("/")); }
    fs.writeFileSync(path.join(work, "desc", `g${g.g}.txt`), [...need].map(p => `${p};Describes ${p.split("/").at(-1)}.`).join("\n") + "\n");
  }
}

/** a sample project mixing docs and code, big enough for 3+ groups */
export function sampleProject() {
  const f = {};
  for (let i = 1; i <= 9; i++) {
    f[`docs/topic${i}.md`] = `# Topic ${i}\n\nIntro paragraph for topic ${i}.\n\n## Rules\n\n- [R-${i}01] First rule of topic ${i}.\n- [R-${i}02] Second rule of topic ${i}.\n\n| Key | Meaning |\n|---|---|\n| a | alpha ${i} |\n`;
  }
  f["src/server.go"] = GO;
  f["src/util.py"] = PY;
  return sampleFiles(f);
}
const sampleFiles = f => project(f, { ignore: "ignored.md\n" });

const fill = (n, tpl) => Array.from({ length: n }, (_, i) => tpl(i)).join("\n");
export const GO = `package server

import (
\t"fmt"
)

// Handle answers one request and validates the caller name before greeting.
func Handle(name string) string {
${fill(8, i => `\tstep${i} := compute(name, ${i}, "alpha", "beta", "gamma", "delta")`)}
\tif name == "" {
\t\treturn "empty"

\t}
\treturn fmt.Sprintf("hi %s", name)
}

// Helper formats a value for the log line and counts how often it was called.
func Helper(v int) string {
${fill(8, i => `\tlogLine${i} := format(v, ${i}, "alpha", "beta", "gamma", "delta", "epsilon")`)}
\treturn "ok"
}

// Tiny is small.
func Tiny() int { return 1 }
`;
export const PY = `import os


@decorator
def load(path):
    """Load a file and normalise every line of it before returning the text."""
${fill(8, i => `    step_${i} = normalise(path, ${i}, "alpha", "beta", "gamma", "delta", "epsilon")`)}

    with open(path) as f:
        return f.read()


class Cache:
    """Keeps recent values."""
${fill(8, i => `    attr_${i} = make_attribute(${i}, "alpha", "beta", "gamma", "delta", "epsilon", "zeta")`)}

    def get(self, k):
        return k
`;
