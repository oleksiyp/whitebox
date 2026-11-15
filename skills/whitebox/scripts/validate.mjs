// node tools/validate.mjs whitebox.json
import { readFileSync } from "node:fs";
String.prototype.trim = function () { return this.replace(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/g, ""); }; // ASCII-only, same as whitebox.mjs
import { resolve, dirname } from "node:path";
const f = process.argv[2] || "whitebox.json";
const T = JSON.parse(readFileSync(f, "utf8"));
const base = resolve(dirname(f), T.root || ".");
const errs = [], warn = [], ids = new Set(), leaves = [], cache = {};
const lines = file => cache[file] ??= readFileSync(resolve(base, file), "utf8").replace(/\r\n/g, "\n").split("\n");
const words = s => s.trim().split(/[ \t\r\n\f\v]+/).length;
let depth = 0;
(function walk(n, d, path) {
  depth = Math.max(depth, d);
  const p = path + "/" + n.title;
  if (!n.id || ids.has(n.id)) errs.push(`${p}: missing/duplicate id ${n.id}`); ids.add(n.id);
  if (d > 0 && !(typeof n.title === "string" && words(n.title) >= 2 && words(n.title) <= 4)) errs.push(`${p}: title must be 2-4 words`);
  if (n.children) {
    if (!n.children.length) errs.push(`${p}: empty branch`);
    if (d === 0 && (n.children.length < 3 || n.children.length > 8)) warn.push(`root has ${n.children.length} top-level branches (want 3-8)`);
    if (d > 8) warn.push(`${p}: depth ${d} (>8)`);
    if (n.children.length < 2 && d > 0) warn.push(`${p}: single-child branch`);
    if (n.children.length > 9) warn.push(`${p}: ${n.children.length} children (>9)`);
    const t = n.children.map(c => c.title); if (new Set(t).size !== t.length) errs.push(`${p}: duplicate sibling titles`);
    const lastLine = {};
    for (const c of n.children.filter(c => !c.children)) { if (c.file && c.start <= (lastLine[c.file] ?? 0)) warn.push(`${p}: "${c.title}" out of source order`); lastLine[c.file] = c.start; }
    n.children.forEach(c => walk(c, d + 1, p));
  } else {
    leaves.push(n);
    if (!n.file || !Number.isInteger(n.start) || !Number.isInteger(n.end) || n.end < n.start) return errs.push(`${p}: bad file/start/end`);
    let L; try { L = lines(n.file); } catch { return errs.push(`${p}: cannot read ${n.file}`); }
    const real = L.slice(n.start - 1, n.end).join("\n");
    if (real !== n.text) errs.push(`${p}: text differs from ${n.file}:${n.start}-${n.end}`);
    if (n.kind === "code" && !n.description) warn.push(`${p}: code piece without description`);
    if (n.kind !== "code" && words(n.text) > 250 && n.end > n.start) errs.push(`${p}: leaf has ${words(n.text)} words (max 250; spans ${n.end - n.start + 1} lines, split it)`); else if (n.kind !== "code" && words(n.text) > 120) warn.push(`${p}: leaf has ${words(n.text)} words (>120)`);
    if (!L[n.start - 1].trim() || !L[n.end - 1].trim()) errs.push(`${p}: leaf starts or ends on a blank line`);
  }
})(T.tree, 0, "");
// overlap + coverage
const by = {}; leaves.forEach(l => (by[l.file] ??= []).push(l));
for (const [file, ls] of Object.entries(by)) {
  ls.sort((a, b) => a.start - b.start);
  for (let i = 1; i < ls.length; i++) if (ls[i].start <= ls[i - 1].end) errs.push(`${file}: leaves overlap at line ${ls[i].start} ("${ls[i].title}")`);
  const covered = new Set(); ls.forEach(l => { for (let k = l.start; k <= l.end; k++) covered.add(k); });
  const isCode = ls.some(l => l.kind === "code"); const miss = []; let fence = false;
  lines(file).forEach((t, i) => { if (/^```/.test(t)) fence = !fence; if (t.trim() && (isCode || fence || !/^#{1,6}[ \t\r\n\f\v]/.test(t)) && !covered.has(i + 1)) miss.push(i + 1); });
  if (miss.length) errs.push(`${file}: ${miss.length} content lines not covered, e.g. ${miss.slice(0, 8).join(",")}`);
}
console.log(`${leaves.length} leaves, ${ids.size - leaves.length} branches, depth ${depth}, files: ${Object.keys(by).join(", ")}`);
warn.forEach(w => console.log("warn:", w)); errs.forEach(e => console.log("ERROR:", e));
process.exit(errs.length ? 1 : 0);
