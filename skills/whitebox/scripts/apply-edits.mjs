// Write edits made in the whitebox editor back to the markdown files.
// node tools/apply-edits.mjs edits.json [--root DIR] [--drop-excluded] [--dry-run]
// Every change is verified: the lines on disk must still equal the leaf's original text,
// otherwise that file is left untouched and reported as a conflict.
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const a = process.argv.slice(2);
const flag = n => a.includes(n), opt = n => (a.includes(n) ? a[a.indexOf(n) + 1] : null);
const jf = a.find(x => !x.startsWith("--") && x !== opt("--root"));
if (!jf) { console.error("usage: apply-edits.mjs edits.json [--root DIR] [--drop-excluded] [--dry-run]"); process.exit(2); }
const E = JSON.parse(readFileSync(jf, "utf8"));
const root = resolve(opt("--root") || E.root || ".");
const codeEx = (E.excluded || []).filter(e => e.kind === "code").length, intents = (E.intents || []).length;
const ops = [...E.edits.map(e => ({ ...e, kind: "edit" })), ...(flag("--drop-excluded") ? (E.excluded || []).filter(e => e.kind !== "code").map(e => ({ ...e, kind: "drop" })) : [])];
const byFile = {}; ops.forEach(o => (byFile[o.file] ??= []).push(o));
let changed = 0, conflicts = 0;
for (const [file, list] of Object.entries(byFile)) {
  const p = resolve(root, file), raw = readFileSync(p, "utf8"), crlf = raw.includes("\r\n");
  const L = raw.replace(/\r\n/g, "\n").split("\n");
  list.sort((x, y) => y.start - x.start);
  let bad = false;
  for (const o of list) if (L.slice(o.start - 1, o.end).join("\n") !== o.before) { console.log(`CONFLICT ${file}:${o.start}-${o.end} no longer matches the original; skipping file`); bad = true; conflicts++; }
  for (let i = 1; i < list.length; i++) if (list[i].end >= list[i - 1].start) { console.log(`CONFLICT ${file}: overlapping ranges at ${list[i - 1].start}`); bad = true; conflicts++; }
  if (bad) continue;
  for (const o of list) {
    const n = o.end - o.start + 1;
    if (o.kind === "edit") { L.splice(o.start - 1, n, ...o.after.split("\n")); console.log(`edit  ${file}:${o.start}-${o.end}`); }
    else { L.splice(o.start - 1, n); console.log(`drop  ${file}:${o.start}-${o.end}  ${o.path || ""}`); }
    changed++;
  }
  let out = L.join("\n");
  if (list.some(o => o.kind === "drop")) out = out.replace(/\n{3,}/g, "\n\n"); // collapse blank runs left by drops
  if (crlf) out = out.replace(/\n/g, "\r\n");
  if (!flag("--dry-run")) writeFileSync(p, out);
}
if (intents || codeEx) console.log(`note: source code is never rewritten or deleted by this tool: ${intents} behaviour change note(s) and ${codeEx} excluded code piece(s) were ignored (hand the intents to an implementer).`);
console.log(`${flag("--dry-run") ? "[dry run] " : ""}${changed} change(s) applied, ${conflicts} conflict(s)`);
process.exit(conflicts ? 1 : 0);
