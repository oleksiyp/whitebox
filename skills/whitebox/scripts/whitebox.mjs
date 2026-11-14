#!/usr/bin/env node
// whitebox: turn a project (markdown + source code) into one overseeable, editable tree.
// Deterministic steps live here; a cheap model (haiku agents) only writes titles/paths.
//
//   split <dir|file...> --work W      segment into pieces, form ~sqrt(N) balanced groups + windows
//   window G N --work W               print the instructions+data for one haiku window task
//   check G N --work W                validate a window's output (agents run this until OK)
//   merge-input --work W              print instructions+outlines for the merger agent
//   apply-merge --work W              apply W/merge.txt -> W/tree.paths (+ width report)
//   describe-input G --work W         print instructions for the description pass of group G
//   build --work W [--out f.json]     tree.paths + descriptions -> whitebox.json + whitebox.paths
//   status --work W                   which windows/groups are done
//   check-all / groups-args           workflow helpers (failing windows; JSON args for the workflow)
//   reshape-count                     read-only: how many branches are wider than 9
//   reshape-list|reshape-input N|check-reshape N|apply-reshape   regroup branches wider than 9 (reshape-list resets a round)
//   estimate --work W                 print the expected agents / tokens / time again
//
// Zero dependencies: Node >= 18 and git (optional, for .gitignore-aware file selection).
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";

const argv = process.argv.slice(2);
const cmd = argv[0];
const VAL = ["--work", "--out", "--window", "--groups", "--max-kb", "--include", "--exclude"];
const opt = (n, d) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : d);
const pos = argv.slice(1).filter((a, i) => !a.startsWith("--") && !VAL.includes(argv[i]));
const WORK = path.resolve(opt("--work", ".whitebox"));
const WIN = +opt("--window", 220);
const MAX = 80;
const wp = (...p) => path.join(WORK, ...p);
const readJ = p => JSON.parse(fs.readFileSync(p, "utf8"));
const die = m => { console.error(m); process.exit(1); };

/* ---------------- segmenter (deterministic) ---------------- */
const SELF = path.relative(process.cwd(), process.argv[1]);
const W = s => (s.match(/\S+/g) || []).length;
const isHeading = l => /^ {0,3}#{1,6}\s+\S/.test(l);
const fenceRe = /^ {0,3}(`{3,}|~{3,})/;
const listRe = /^( {0,3})([-*+]|\d{1,3}[.)])\s+/;
const H = s => crypto.createHash("sha1").update(s).digest("hex").slice(0, 10);
const clean = s => s.replace(/[`*_]|\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/\s+/g, " ").trim();
const txt = (L, s, e) => L.slice(s - 1, e).join("\n");
function parseFile(L) {
  const n = L.length, ev = []; let i = 0;
  while (i < n) {
    const l = L[i]; if (!l.trim()) { i++; continue; }
    let m;
    if ((m = l.match(fenceRe))) { let j = i + 1; while (j < n && !L[j].trim().startsWith(m[1].slice(0, 3))) j++; ev.push({ t: "u", s: i + 1, e: Math.min(j, n - 1) + 1 }); i = j + 1; continue; }
    if (isHeading(l)) { const h = l.match(/^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/); ev.push({ t: "h", level: h[1].length, raw: clean(h[2]) }); i++; continue; }
    if (/^\s*\|/.test(l)) { let j = i; while (j + 1 < n && /^\s*\|/.test(L[j + 1])) j++; ev.push({ t: "u", s: i + 1, e: j + 1 }); i = j + 1; continue; }
    if (listRe.test(l)) {
      let j = i;
      while (j + 1 < n) {
        const nx = L[j + 1];
        if (!nx.trim()) { let k = j + 1; while (k < n && !L[k].trim()) k++; if (k < n && /^( {2,}|\t)\S/.test(L[k]) && !isHeading(L[k])) { j = k; continue; } break; }
        if (isHeading(nx) || (fenceRe.test(nx) && !/^\s/.test(nx)) || (listRe.test(nx) && !/^ {2,}/.test(nx)) || /^\|/.test(nx)) break;
        j++;
      }
      ev.push({ t: "u", s: i + 1, e: j + 1 }); i = j + 1; continue;
    }
    let j = i;
    while (j + 1 < n && L[j + 1].trim() && !isHeading(L[j + 1]) && !fenceRe.test(L[j + 1]) && !listRe.test(L[j + 1]) && !/^\s*\|/.test(L[j + 1])) j++;
    ev.push({ t: "u", s: i + 1, e: j + 1 }); i = j + 1;
  }
  const root = { raw: "", level: 0, kids: [] }, stack = [root];
  for (const e of ev) {
    if (e.t === "h") { while (stack.at(-1).level >= e.level) stack.pop(); const h = { raw: e.raw, level: e.level, kids: [] }; stack.at(-1).kids.push(h); stack.push(h); }
    else stack.at(-1).kids.push({ s: e.s, e: e.e });
  }
  return root;
}
function splitUnit(L, u, max = MAX, code = false) {
  if (W(txt(L, u.s, u.e)) <= max) return [u];
  const out = []; let cs = u.s, acc = 0, lastBlank = 0;
  for (let i = u.s; i <= u.e; i++) {
    const lw = W(L[i - 1]);
    if (code && !L[i - 1].trim() && acc >= max / 3) lastBlank = i;
    if (acc > 0 && acc + lw > max && L[i - 1].trim()) {
      let brk = i; if (code && lastBlank && lastBlank > cs) brk = lastBlank + 1;
      let e = brk - 1; while (!L[e - 1].trim()) e--; out.push({ s: cs, e }); cs = brk; lastBlank = 0;
      acc = 0; for (let k = cs; k <= i; k++) acc += W(L[k - 1]); continue;
    }
    acc += lw;
  }
  let e = u.e; while (!L[e - 1].trim()) e--; out.push({ s: cs, e });
  return out;
}
function pack(L, units, max = MAX, small = 20, code = false) {
  const out = []; let cur = null;
  for (const u0 of units) for (const u of splitUnit(L, u0, max, code)) {
    const w = W(txt(L, u.s, u.e));
    if (cur && (cur.w < small || w < small) && cur.w + w <= max) { cur.e = u.e; cur.w += w; }
    else { if (cur) out.push(cur); cur = { s: u.s, e: u.e, w }; }
  }
  if (cur) out.push(cur);
  return out;
}
function piecesOf(L) {
  const out = [];
  (function w(h, hp) {
    let run = []; const flush = () => { pack(L, run).forEach(p => out.push({ s: p.s, e: p.e, w: p.w, hp: hp.join(" > ") })); run = []; };
    for (const k of h.kids) { if (k.raw === undefined) run.push(k); else { flush(); w(k, [...hp, k.raw]); } }
    flush();
  })(parseFile(L), []);
  return out;
}
const snip = (s, n) => { const w = clean(s).split(/\s+/); return w.slice(0, n).join(" ") + (w.length > n ? " …" : ""); };
const walk = (d, o = [], all = false) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { if (e.name.startsWith(".") || e.name === "node_modules") continue; const p = path.join(d, e.name); e.isDirectory() ? walk(p, o, all) : (all || /\.(md|markdown)$/i.test(e.name)) && o.push(p); } return o; };

/* ---------------- project file selection ---------------- */
const CODE_EXT = { go: "go", ts: "ts", tsx: "tsx", js: "js", jsx: "jsx", mjs: "js", cjs: "js", py: "py", rs: "rust", java: "java", kt: "kotlin", c: "c", h: "c", cc: "cpp", cpp: "cpp", hpp: "cpp", cs: "csharp", rb: "ruby", php: "php", swift: "swift", sh: "sh", bash: "sh", sql: "sql", proto: "proto", star: "starlark", lua: "lua", scala: "scala", ex: "elixir", exs: "elixir", dart: "dart" };
const CFG_EXT = new Set(["yaml", "yml", "json", "toml", "ini", "tf", "tpl", "cfg", "conf", "xml"]);
const SKIP_DIRS = new Set(["node_modules", "vendor", "dist", "build", "out", "target", "coverage", "__pycache__", "venv", "site-packages", "bower_components", "testdata", "fixtures", "__snapshots__", "golden", "third_party", "generated"]);
const LOCKS = new Set(["go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "poetry.lock", "gemfile.lock", "composer.lock", "bun.lockb"]);
const TEST_RE = /(_test\.go|\.test\.[a-z]+|\.spec\.[a-z]+|(^|\/)(tests?|__tests__|e2e)\/|(^|\/)test_[^/]*\.py|_test\.py|Test\.java|Tests?\.cs)$/;
const SECRET_RE = /(^|\/)(\.env[^/]*|[^/]*\.(pem|key|p12|pfx|jks|keystore|kdbx|crt|cer|asc)|id_(rsa|dsa|ecdsa|ed25519)[^/]*|[^/]*(secret|credential|password|passwd|token)s?[^/]*\.(json|ya?ml|toml|ini|txt|env|conf|cfg)|\.?netrc|\.npmrc|\.pypirc|[^/]*\.tfstate(\.backup)?|[^/]*\.tfvars)$/i;
const GEN_RE = /(Code generated|DO NOT EDIT|@generated|autogenerated|auto-generated|<auto-generated|GENERATED FILE)/i;
const globRe = g => new RegExp("^" + g.trim().replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\u0001").replace(/\*/g, "[^/]*").replace(/\u0001/g, ".*").replace(/\?/g, "[^/]") + "$");
function collectProject(dir) {
  const maxKb = +opt("--max-kb", 300), incl = (opt("--include", "") || "").split(",").filter(Boolean).map(globRe), excl = (opt("--exclude", "") || "").split(",").filter(Boolean).map(globRe);
  const withTests = argv.includes("--tests"), withCfg = argv.includes("--config");
  let rels, mode = "git";
  try { rels = execFileSync("git", ["-C", dir, "ls-files", "-co", "--exclude-standard", "-z"], { maxBuffer: 1 << 28, stdio: ["ignore", "pipe", "ignore"] }).toString().split("\0").filter(Boolean); }
  catch { mode = "walk"; rels = walk(dir, [], true).map(f => path.relative(dir, f)); }
  const reasons = {}, samples = {}, included = [];
  const skip = (rel, why) => { reasons[why] = (reasons[why] || 0) + 1; (samples[why] ??= []).length < 3 && samples[why].push(rel); };
  for (const rel of rels) {
    const abs = path.join(dir, rel), parts = rel.split("/"), name = parts.at(-1), ext = (name.includes(".") ? name.split(".").pop() : "").toLowerCase();
    if (!fs.existsSync(abs) || !fs.statSync(abs).isFile()) continue;
    const forced = incl.some(r => r.test(rel));
    if (excl.some(r => r.test(rel))) { skip(rel, "excluded by --exclude"); continue; }
    if (!forced) {
      if (parts.some(x => x.startsWith("."))) { skip(rel, "hidden file or directory"); continue; }
      if (parts.slice(0, -1).some(x => SKIP_DIRS.has(x))) { skip(rel, "generated / vendored / fixture directory"); continue; }
      if (SECRET_RE.test(rel)) { skip(rel, "looks like a secret or key file (never sent to a model; use --include to override)"); continue; }
      if (LOCKS.has(name.toLowerCase())) { skip(rel, "lockfile"); continue; }
      if (/\.min\.|\.map$/.test(name)) { skip(rel, "minified / sourcemap"); continue; }
      const kind = ext === "md" || ext === "markdown" ? "doc" : CODE_EXT[ext] ? "code" : CFG_EXT.has(ext) ? "config" : null;
      if (!kind) { skip(rel, "other file type (binary, media, text data)"); continue; }
      if (kind === "config" && !withCfg) { skip(rel, "config file (add --config to include)"); continue; }
      if (kind === "code" && !withTests && TEST_RE.test(rel)) { skip(rel, "test file (add --tests to include)"); continue; }
      if (kind !== "doc" && fs.statSync(abs).size > maxKb * 1024) { skip(rel, `source file larger than ${maxKb} KB (add --max-kb or --include)`); continue; }
      if (kind === "doc" && fs.statSync(abs).size > 8 * 1024 * 1024) { skip(rel, "markdown larger than 8 MB"); continue; }
    }
    const buf = fs.readFileSync(abs); if (buf.subarray(0, 4096).includes(0)) { skip(rel, "binary"); continue; }
    if (!forced && GEN_RE.test(buf.subarray(0, 600).toString("utf8").split("\n").slice(0, 6).join("\n"))) { skip(rel, "generated code header"); continue; }
    included.push(abs);
  }
  return { files: included, mode, reasons, samples, total: rels.length };
}

/* ---------------- code segmenter (top-level declarations) ---------------- */
const DECL = /^(func|type|class|def|fn|pub|impl|struct|enum|trait|interface|const|var|let|export|import|package|module|use|async|public|private|protected|static|abstract|final|namespace|template|extern|mod|object|data|sealed|open)\b/;
const LEAD = /^(\/\/|\/\*|#(?!include|define|if|endif|pragma|!)|--|@[A-Za-z_(])/;
function codeUnits(L, lang) {
  const n = L.length, units = []; let depth = 0, inBlock = false, cur = null, chain = false, lastNb = 0, blankSince = false;
  const py = lang === "py" || lang === "sh" || lang === "ruby";
  const bal = l => {
    let s = l;
    if (inBlock) { const k = s.indexOf("*/"); if (k < 0) return 0; s = s.slice(k + 2); inBlock = false; }
    if (!py) { s = s.replace(/\/\*.*?\*\//g, ""); const k = s.indexOf("/*"); if (k >= 0) { inBlock = true; s = s.slice(0, k); } }
    s = s.replace(/"(\\.|[^"\\])*"|'(\\.|[^'\\])*'|`[^`]*`/g, "");
    s = s.replace(py ? /#.*$/ : /\/\/.*$/, "");
    let d = 0; for (const c of s) { if ("{([".includes(c)) d++; else if ("})]".includes(c)) d--; } return d;
  };
  for (let i = 0; i < n; i++) {
    const l = L[i];
    if (!l.trim()) { blankSince = true; continue; }
    const col0 = !/^\s/.test(l);
    if (col0 && !inBlock) {
      if (DECL.test(l)) depth = 0;
      const lead = LEAD.test(l);
      const closer = /^[})\]]/.test(l) || (lang === "py" && /^(else|elif|except|finally)\b/.test(l));
      if (depth <= 0 && !closer && !(chain && !blankSince)) { if (cur) units.push(cur); cur = { s: i + 1, e: i + 1 }; }
      chain = lead;
    } else if (!col0) chain = false;
    depth += bal(l); if (depth < 0) depth = 0;
    if (!cur) cur = { s: i + 1, e: i + 1 };
    cur.e = i + 1; blankSince = false;
  }
  if (cur) units.push(cur);
  return units;
}
function codeSnippet(L, s, e) { return L.slice(s - 1, e).filter(x => x.trim()).slice(0, 10).map(x => x.trim().slice(0, 100)).join(" ⏎ "); }

/* ---------------- split ---------------- */
function cmdSplit() {
  if (!pos.length) die("usage: split <dir|file...> --work W [--tests] [--config] [--max-kb 300] [--include globs] [--exclude globs]");
  let files, ROOT, report = null;
  if (pos.length === 1 && fs.statSync(pos[0]).isDirectory()) {
    ROOT = path.resolve(pos[0]); report = collectProject(ROOT); files = report.files;
  } else { files = pos.map(f => path.resolve(f)); ROOT = path.dirname(files[0]); while (!files.every(f => f.startsWith(ROOT + path.sep))) ROOT = path.dirname(ROOT); }
  files.sort((a, b) => path.relative(ROOT, a).toLowerCase().localeCompare(path.relative(ROOT, b).toLowerCase()));
  const pieces = [], fl = [];
  files.forEach((abs, fi) => {
    const rel = path.relative(ROOT, abs), raw = fs.readFileSync(abs, "utf8"), L = raw.replace(/\r\n/g, "\n").split("\n");
    if (L.at(-1) === "") L.pop();
    const ext = (rel.split(".").pop() || "").toLowerCase(), lang = CODE_EXT[ext], first = pieces.length + 1;
    if (lang) {
      for (const u of pack(L, codeUnits(L, lang), 200, 40, true)) pieces.push({ i: pieces.length + 1, f: fi, s: u.s, e: u.e, w: u.w, hp: "", k: "c", lang, sn: codeSnippet(L, u.s, u.e), h: H(txt(L, u.s, u.e)) });
    } else for (const p of piecesOf(L)) pieces.push({ i: pieces.length + 1, f: fi, s: p.s, e: p.e, w: p.w, hp: p.hp, sn: snip(txt(L, p.s, p.e), 18), h: H(txt(L, p.s, p.e)) });
    fl.push({ rel, bytes: Buffer.byteLength(raw), first, last: pieces.length, lang: lang || "md" });
  });
  if (report) {
    const by = {}; fl.forEach(f => by[f.lang] = (by[f.lang] || 0) + 1);
    console.log(`selection (${report.mode === "git" ? "git: tracked + untracked, honouring .gitignore" : "directory walk"}): ${files.length} of ${report.total} files included`);
    console.log("  included: " + Object.entries(by).map(([k, v]) => `${v} ${k}`).join(", "));
    for (const [why, n] of Object.entries(report.reasons).sort((a, b) => b[1] - a[1])) console.log(`  skipped ${String(n).padStart(4)}  ${why}   e.g. ${report.samples[why].join(", ")}`);
    fs.mkdirSync(WORK, { recursive: true }); fs.writeFileSync(wp("selection.json"), JSON.stringify({ included: fl.map(f => f.rel), reasons: report.reasons, samples: report.samples }, null, 1));
  }
  // families (name-2, name-3 stay together), contiguous balanced groups by bytes
  const fam = []; fl.forEach(f => { const k = f.rel.replace(/-\d+(\.(md|markdown))$/i, "$1"); const last = fam.at(-1); if (last && last.k === k) last.files.push(f); else fam.push({ k, files: [f] }); });
  fam.forEach(x => x.bytes = x.files.reduce((a, f) => a + f.bytes, 0));
  const total = fam.reduce((a, f) => a + f.bytes, 0), M = Math.max(1, Math.min(fam.length, Math.floor(Math.sqrt(files.length))));
  const groups = []; let cur = [], cum = 0;
  fam.forEach((x, idx) => {
    cur.push(x); cum += x.bytes;
    const left = fam.length - idx - 1, need = M - groups.length - 1; // families left vs groups still to open
    if (groups.length < M - 1 && (cum >= total * (groups.length + 1) / M || left <= need)) { groups.push(cur); cur = []; }
  });
  if (cur.length) groups.push(cur);
  const G = groups.map((g, gi) => {
    const fs_ = g.flatMap(x => x.files), from = fs_[0].first, to = fs_.at(-1).last;
    const windows = []; let ws = from;
    while (ws <= to) {
      let we = Math.min(to, ws + WIN - 1);
      if (we < to) { // prefer cutting at a file boundary within [ws+WIN*0.7, ws+WIN*1.3]
        let best = null; for (const f of fs_) if (f.last >= ws + WIN * 0.7 && f.last <= Math.min(to, ws + WIN * 1.3)) { if (best === null || Math.abs(f.last - (ws + WIN - 1)) < Math.abs(best - (ws + WIN - 1))) best = f.last; }
        if (best !== null) we = best;
      }
      windows.push({ w: windows.length + 1, from: ws, to: we }); ws = we + 1;
    }
    return { g: gi + 1, files: fs_.map(f => f.rel), bytes: g.reduce((a, x) => a + x.bytes, 0), from, to, windows };
  });
  fs.mkdirSync(wp("out"), { recursive: true }); fs.mkdirSync(wp("desc"), { recursive: true });
  fs.writeFileSync(wp("pieces.json"), JSON.stringify({ root: ROOT, files: fl, pieces }));
  fs.writeFileSync(wp("groups.json"), JSON.stringify(G, null, 1));
  console.log(`${files.length} files, ${pieces.length} pieces -> ${G.length} groups`);
  const est = estimateOf(pieces, G); fs.writeFileSync(wp("estimate.json"), JSON.stringify(est)); printEstimate(est);
  G.forEach(g => console.log(`  group ${g.g}: ${g.files.length} files, ${(g.bytes / 1024) | 0} KB, ${g.to - g.from + 1} pieces, ${g.windows.length} windows`));
}

/* ---------------- cost estimate ---------------- */
// Calibrated on four real runs (11 to 176 agents): a Haiku agent costs ~60k tokens whatever its job (0.04M-0.085M),
// so the token estimate is agents x 0.06M. Agents = windows (+retries) + one describe per group + one reshape per wide branch
// (about one per 150 pieces) + a few coordination agents.
function estimateOf(pieces, G) {
  const code = pieces.filter(p => p.k === "c").length, doc = pieces.length - code;
  const windows = G.reduce((a, g) => a + g.windows.length, 0);
  const agents = Math.round(windows * 1.2 + G.length + pieces.length / 150 + 6);
  const longest = Math.max(...G.map(g => g.windows.length));
  const minutes = Math.round(longest * 3.2 + 6 + Math.min(10, pieces.length / 1500));
  return { pieces: pieces.length, docPieces: doc, codePieces: code, windows, groups: G.length, agents, tokensM: +(agents * 0.06).toFixed(1), minutes };
}
function printEstimate(e) {
  console.log(`estimate: ~${e.agents} haiku agents, ~${e.tokensM}M tokens, ~${e.minutes} min wall-clock (${e.docPieces} doc + ${e.codePieces} code pieces, ${e.windows} windows). Rough: real runs landed within 0.5x-2x.`);
}
function cmdEstimate() { printEstimate(readJ(wp("estimate.json"))); }

/* ---------------- shared readers ---------------- */
const P = () => (P.c ??= readJ(wp("pieces.json")));
const GR = () => (GR.c ??= readJ(wp("groups.json")));
const outFile = (g, w) => wp("out", `g${g}-w${w}.txt`);
const sumFile = (g, w) => wp("out", `g${g}-w${w}.sum`);
function readOut(g, w) {
  const f = outFile(g, w); if (!fs.existsSync(f)) return null;
  return fs.readFileSync(f, "utf8").split("\n").map(l => l.trim()).filter(Boolean).map(l => { const k = l.indexOf(";"), rest = l.slice(k + 1), k2 = rest.indexOf(";"); return { id: +l.slice(0, k), path: (k2 < 0 ? rest : rest.slice(0, k2)).trim(), desc: k2 < 0 ? "" : rest.slice(k2 + 1).trim() }; });
}
const segsOk = s => { const w = s.trim().split(/\s+/).filter(Boolean); return w.length >= 2 && w.length <= 4 && !/[;]/.test(s); };

/* ---------------- window ---------------- */
function cmdWindow() {
  const g = +pos[0], w = +pos[1], G = GR().find(x => x.g === g); if (!G) die("no such group");
  const win = G.windows.find(x => x.w === w); if (!win) die("no such window");
  const prevSum = w > 1 && fs.existsSync(sumFile(g, w - 1)) ? fs.readFileSync(sumFile(g, w - 1), "utf8").trim() : "";
  const vocab = new Map();
  for (let k = 1; k < w; k++) for (const r of readOut(g, k) || []) { const s = r.path.split("/"); s.pop(); for (let d = 1; d <= Math.min(3, s.length); d++) { const p = s.slice(0, d).join("/"); vocab.set(p, (vocab.get(p) || 0) + 1); } }
  let vl = [...vocab].sort((a, b) => a[0].localeCompare(b[0])); if (vl.length > 160) vl = vl.filter(([p]) => p.split("/").length <= 2);
  const out = `${path.relative(process.cwd(), outFile(g, w))}`, sum = `${path.relative(process.cwd(), sumFile(g, w))}`;
  let hasCode = false; for (let i = win.from; i <= win.to; i++) if (P().pieces[i - 1].k === "c") { hasCode = true; break; }
  const codeRules = hasCode ? `
CODE PIECES (marked [code <lang>]) - INVERT THE CODE INTO SPECIFICATION
- For every [code] piece write ONE EXTRA FIELD, the description:  <id>;<path>;<description>   (required for code pieces, never for documentation pieces).
- The description states WHAT the system does or guarantees at that point, as a requirement a reader could re-implement from: behaviour, inputs/outputs, rules, invariants, error handling, side effects. Plain present-tense English, 1-2 sentences, at most 40 words, no ";" and no code. Do not narrate the code ("loops over...", "calls..."); name public identifiers only when the behaviour depends on them.
- Path segments name CAPABILITIES and behaviours ("Retry Failed Deployments", "Reject Expired Tokens"), never files, packages, functions or types. Group by capability across files, not by directory layout.
- Imports, boilerplate and trivial glue still get a piece line (path ending like "Module Setup") with a few-word description.
` : "";
  console.log(`TASK  (group ${g}, window ${w}/${G.windows.length}: pieces ${win.from}-${win.to})
You are building one branch of an outline of a project (documentation and/or source code). Below are NUMBERED PIECES (short excerpts, in document order).
Place every piece in a tree by writing ONE LINE per piece:

    <id>;<Theme>/<Sub Theme>/.../<Piece Title>${hasCode ? "[;<description> for code pieces]" : ""}

RULES
- Every id from ${win.from} to ${win.to} exactly once, ascending. Nothing else in the file (no comments, no blank explanations).
- Each path segment is 2-4 words, Title Case, no ";" "/" quotes or trailing punctuation. The LAST segment names that piece's single idea; the segments before it are branches.
- Depth 3 to 5 segments. Aim for 2-9 children per branch: split a bigger one by adding a sub-branch level; do not make single-child branches.
- Group by MEANING, not blindly by heading or file: consecutive pieces of one section usually share a branch, but a heading is only a hint.
- Reuse branches from EXISTING BRANCHES below (exact spelling) when a piece belongs there; add new branches only when needed.
- Full paths must be unique, and one piece's path must never equal a prefix of another's.
- Never use a bare requirement id as a segment ("R-012" alone); "R-012 Black Keys" is fine.
${codeRules}
DO THIS
1. Write the lines to  ${out}  with the Write tool.
2. Write a summary (max 60 words, plain text) to  ${sum}  saying what this group covers so far (build on the previous summary).
3. Run:  node ${SELF} check ${g} ${w} --work ${path.relative(process.cwd(), WORK) || "."}   and fix the files until it prints OK.
Reply with just "done".

PREVIOUS SUMMARY: ${prevSum || "(first window)"}

EXISTING BRANCHES (path (pieces so far)):
${vl.length ? vl.map(([p, n]) => `${p} (${n})`).join("\n") : "(none yet)"}

PIECES`);
  let lastF = -1, lastHp = null;
  for (let i = win.from; i <= win.to; i++) {
    const p = P().pieces[i - 1];
    if (p.f !== lastF) { console.log(`\n## FILE ${P().files[p.f].rel}`); lastF = p.f; lastHp = null; }
    if (p.k === "c") { console.log(`${p.i} [code ${p.lang}] ${p.sn}`); continue; }
    if (p.hp !== lastHp) { console.log(`# ${p.hp || "(no heading)"}`); lastHp = p.hp; }
    console.log(`${p.i} ${p.sn}`);
  }
}

/* ---------------- check ---------------- */
function checkWindow(g, w) {
  const G = GR().find(x => x.g === g), win = G.windows.find(x => x.w === w);
  const errs = [], rows = readOut(g, w);
  if (!rows) return [`${outFile(g, w)} not found`];
  const seen = new Set(), paths = new Map();
  rows.forEach((r, n) => {
    if (!Number.isInteger(r.id) || r.id < win.from || r.id > win.to) { errs.push(`line ${n + 1}: bad id "${r.id}" (need ${win.from}-${win.to}, format id;path)`); return; }
    if (seen.has(r.id)) errs.push(`id ${r.id} appears twice`); seen.add(r.id);
    const s = r.path.split("/");
    if (s.length < 2 || s.length > 6) errs.push(`id ${r.id}: depth ${s.length} (need 3-5 segments, minimum 2)`);
    s.forEach(x => { if (!segsOk(x)) errs.push(`id ${r.id}: segment "${x}" must be 2-4 words`); });
    if (P().pieces[r.id - 1]?.k === "c") { const dw = W(r.desc); if (!r.desc) errs.push(`id ${r.id}: code piece needs a description (id;path;description)`); else if (dw > 45) errs.push(`id ${r.id}: description has ${dw} words (max 40)`); }
    if (paths.has(r.path)) errs.push(`id ${r.id}: path duplicates id ${paths.get(r.path)} ("${r.path}")`); paths.set(r.path, r.id);
  });
  for (const r of rows) for (const [p, id] of paths) if (p.startsWith(r.path + "/")) { errs.push(`id ${r.id}: path "${r.path}" is also a prefix of id ${id}'s path`); break; }
  const miss = []; for (let i = win.from; i <= win.to; i++) if (!seen.has(i)) miss.push(i);
  if (miss.length) errs.push(`${miss.length} ids missing: ${miss.slice(0, 20).join(",")}${miss.length > 20 ? "…" : ""}`);
  if (!fs.existsSync(sumFile(g, w))) errs.push(`summary file ${sumFile(g, w)} missing`);
  else if (W(fs.readFileSync(sumFile(g, w), "utf8")) > 120) errs.push("summary longer than 120 words");
  return errs;
}
function cmdCheck() {
  const errs = checkWindow(+pos[0], +pos[1]);
  if (errs.length) { console.log(errs.slice(0, 40).map(e => "ERROR: " + e).join("\n") + (errs.length > 40 ? `\n… ${errs.length - 40} more` : "")); process.exit(1); }
  console.log("OK");
}

function cmdCheckAll() {
  const bad = [];
  for (const G of GR()) for (const w of G.windows) { const e = checkWindow(G.g, w.w); if (e.length) bad.push({ g: G.g, w: w.w, first: e[0] }); }
  console.log(JSON.stringify({ failing: bad.map(b => ({ g: b.g, w: b.w })), detail: bad.slice(0, 10) }));
}

/* ---------------- group trees / merge ---------------- */
function groupRows(g) { const G = GR().find(x => x.g === g), rows = []; for (const w of G.windows) rows.push(...(readOut(g, w.w) || [])); return rows; }
function status() {
  let done = 0, tot = 0; const lines = [];
  for (const G of GR()) { let d = 0; for (const w of G.windows) { tot++; const r = readOut(G.g, w.w); if (r && r.length === w.to - w.from + 1 && fs.existsSync(sumFile(G.g, w.w))) { d++; done++; } } lines.push(`group ${G.g}: ${d}/${G.windows.length} windows`); }
  console.log(lines.join("\n") + `\n${done}/${tot} windows done`);
}
function cmdMergeInput() {
  const lines = [];
  for (const G of GR()) {
    const rows = groupRows(G.g); if (!rows.length) die(`group ${G.g} has no output yet`);
    const sums = G.windows.map(w => w.w).filter(w => fs.existsSync(sumFile(G.g, w))); const sum = sums.length ? fs.readFileSync(sumFile(G.g, sums.at(-1)), "utf8").trim() : "";
    const top = new Map();
    for (const r of rows) { const s = r.path.split("/"); const t = s[0]; if (!top.has(t)) top.set(t, { n: 0, sub: new Map() }); const o = top.get(t); o.n++; if (s.length > 2) o.sub.set(s[1], (o.sub.get(s[1]) || 0) + 1); }
    lines.push(`\n### GROUP ${G.g}  (${G.files.length} files: ${G.files.slice(0, 3).join(", ")}${G.files.length > 3 ? ", …" : ""}; ${rows.length} pieces)\nSummary: ${sum}`);
    for (const [t, o] of top) lines.push(`${G.g};${t}   [${o.n} pieces]  children: ${[...o.sub].slice(0, 8).map(([k, n]) => `${k} (${n})`).join(", ")}`);
  }
  console.log(`TASK
Several agents each outlined a part ("group") of one big specification. Merge their outlines into ONE coherent tree.
Each line under GROUPS is a top-level branch of one group:  <group>;<Top Segment>  [pieces]  children...
Decide where every such branch is mounted in the final tree by writing ONE LINE per (group, top segment):

    <group>;<Top Segment exactly as shown>;<New/Path/Prefix>

The pieces below  <Top Segment>  are re-mounted under  <New/Path/Prefix>  (the top segment is replaced by the prefix).
RULES
- Every (group, top segment) listed exactly once; copy the group number and segment text exactly.
- The final tree must have 3 to 8 top-level branches (first segments of New Path Prefix), each 2-4 words, Title Case.
- Different groups/segments covering the same theme MUST be given the same prefix so they merge into one branch (e.g. several "Screens ..." segments from groups 4-6 all go under "Frontend/Screens And Navigation").
- Prefix has 1 or 2 segments (each 2-4 words, Title Case, no ";" or quotes). Use 2 when a theme needs a parent so that no branch ends up with more than ~9 children. Keep the original document order of themes where possible.
- Don't invent content; do not drop any branch.
Write the lines to ${path.relative(process.cwd(), wp("merge.txt"))} with the Write tool, then run:  node ${SELF} apply-merge --work ${path.relative(process.cwd(), WORK) || "."}   and fix the file until it prints OK. Reply with just "done".

GROUPS${lines.join("\n")}`);
}
function readMerge() {
  const f = wp("merge.txt"); if (!fs.existsSync(f)) die("ERROR: merge.txt not found");
  return fs.readFileSync(f, "utf8").split("\n").map(l => l.trim()).filter(Boolean).map(l => { const a = l.split(";"); return { g: +a[0], top: (a[1] || "").trim(), prefix: (a.slice(2).join(";") || "").trim() }; });
}
function cmdApplyMerge() {
  if (fs.existsSync(wp("reshape.applied")) && !argv.includes("--force")) die("ERROR: reshape results were already applied to tree.paths; re-running apply-merge would discard them. Pass --force only if you want to start the reshape phase over (and delete " + wp("reshape.applied") + ").");
  const M = readMerge(), errs = [], map = new Map();
  for (const m of M) { const k = m.g + ";" + m.top; if (map.has(k)) errs.push(`duplicate mapping for ${k}`); map.set(k, m.prefix); const s = m.prefix.split("/"); if (!m.prefix || s.length > 2 || !s.every(segsOk)) errs.push(`bad prefix "${m.prefix}" for ${k} (1-2 segments of 2-4 words)`); }
  const rowsAll = [];
  for (const G of GR()) {
    const rows = groupRows(G.g), tops = new Set(rows.map(r => r.path.split("/")[0]));
    for (const t of tops) if (!map.has(G.g + ";" + t)) errs.push(`missing mapping for ${G.g};${t}`);
    for (const r of rows) { const s = r.path.split("/"), pre = map.get(G.g + ";" + s[0]); if (pre) rowsAll.push({ g: G.g, id: r.id, path: pre + "/" + s.slice(1).join("/"), desc: r.desc }); }
  }
  const tops = new Set([...map.values()].map(p => p.split("/")[0]));
  if (tops.size < 3 || tops.size > 8) errs.push(`final tree has ${tops.size} top-level branches (need 3-8): ${[...tops].join(" | ")}`);
  if (errs.length) { console.log(errs.slice(0, 30).map(e => "ERROR: " + e).join("\n")); process.exit(1); }
  // resolve leaf/prefix and duplicate collisions deterministically
  rowsAll.sort((a, b) => a.id - b.id);
  const used = new Set(), prefixes = new Set(); rowsAll.forEach(r => { const s = r.path.split("/"); for (let d = 1; d < s.length; d++) prefixes.add(s.slice(0, d).join("/")); });
  let fixes = 0;
  for (const r of rowsAll) { let p = r.path, n = 1; while (used.has(p) || prefixes.has(p)) { n++; const s = r.path.split("/"); const last = s.pop(); p = [...s, (last.split(" ").length >= 4 ? last.split(" ").slice(0, 3).join(" ") : last) + " " + n].join("/"); } if (p !== r.path) { fixes++; r.path = p; } used.add(p); }
  fs.writeFileSync(wp("tree.paths"), rowsAll.map(r => `${r.g};${r.path};${P().files[P().pieces[r.id - 1].f].rel}:${P().pieces[r.id - 1].s}-${P().pieces[r.id - 1].e}`).join("\n") + "\n");
  const leafdesc = {}; for (const r of rowsAll) { const pc = P().pieces[r.id - 1]; if (pc.k === "c" && r.desc) leafdesc[`${P().files[pc.f].rel}:${pc.s}-${pc.e}`] = r.desc; }
  fs.writeFileSync(wp("leafdesc.json"), JSON.stringify(leafdesc));
  // width report
  const kids = new Map(); for (const r of rowsAll) { const s = r.path.split("/"); for (let d = 0; d < s.length; d++) { const par = s.slice(0, d).join("/"), ch = s[d]; if (!kids.has(par)) kids.set(par, new Set()); kids.get(par).add(ch); } }
  const wide = [...kids].filter(([, s]) => s.size > 9).sort((a, b) => b[1].size - a[1].size);
  console.log(`OK  ${rowsAll.length} pieces, ${tops.size} top-level branches${fixes ? `, ${fixes} path collisions auto-renamed` : ""}`);
  if (wide.length) { console.log(`${wide.length} branches have >9 children (worst: ${wide.slice(0, 8).map(([p, s]) => `${p || "(root)"}: ${s.size}`).join("; ")})`); }
}

/* ---------------- describe ---------------- */
function treeRows() { if (!fs.existsSync(wp("tree.paths"))) die("run apply-merge first"); return fs.readFileSync(wp("tree.paths"), "utf8").split("\n").filter(Boolean).map(l => { const a = l.split(";"); return { g: +a[0], path: a[1], range: a[2] }; }); }
function cmdDescribeInput() {
  const g = +pos[0], rows = treeRows().filter(r => r.g === g);
  const br = new Map();
  for (const r of rows) { const s = r.path.split("/"); for (let d = 1; d < s.length && d <= 3; d++) { const p = s.slice(0, d).join("/"); if (!br.has(p)) br.set(p, { n: 0, ch: new Set() }); const o = br.get(p); o.n++; o.ch.add(s[d]); } }
  const list = [...br].sort((a, b) => a[0].localeCompare(b[0]));
  console.log(`TASK
Write a one-sentence description (max 20 words, plain text, no quotes or ";") for each BRANCH below, saying what that part of the specification covers. Use the child titles as evidence.
Output ONE LINE per branch, exactly:   <Branch/Path exactly as shown>;<description>
Write the lines to ${path.relative(process.cwd(), wp("desc", `g${g}.txt`))} with the Write tool (every branch exactly once), then run:
  node ${SELF} check-desc ${g} --work ${path.relative(process.cwd(), WORK) || "."}   and fix until it prints OK. Reply with just "done".

BRANCHES (${list.length})
${list.map(([p, o]) => `${p}   [${o.n} pieces]  children: ${[...o.ch].slice(0, 8).join(", ")}`).join("\n")}`);
}
function cmdCheckDesc() {
  const g = +pos[0], f = wp("desc", `g${g}.txt`); if (!fs.existsSync(f)) die(`ERROR: ${f} not found`);
  const rows = treeRows().filter(r => r.g === g), need = new Set();
  for (const r of rows) { const s = r.path.split("/"); for (let d = 1; d < s.length && d <= 3; d++) need.add(s.slice(0, d).join("/")); }
  const got = new Map(); for (const l of fs.readFileSync(f, "utf8").split("\n").filter(x => x.trim())) { const k = l.indexOf(";"); got.set(l.slice(0, k).trim(), l.slice(k + 1).trim()); }
  const errs = []; for (const p of need) if (!got.get(p)) errs.push(`missing description for "${p}"`); for (const [p, d] of got) { if (!need.has(p)) errs.push(`unknown branch "${p}"`); else if (W(d) > 30) errs.push(`description too long for "${p}"`); }
  if (errs.length) { console.log(errs.slice(0, 30).map(e => "ERROR: " + e).join("\n")); process.exit(1); }
  console.log("OK");
}

/* ---------------- reshape wide branches ---------------- */
const SELFREL = path.relative(process.cwd(), WORK) || ".";
function loadDesc() {
  const all = wp("desc", "_all.txt"), m = new Map();
  const files = fs.existsSync(all) ? [all] : fs.existsSync(wp("desc")) ? fs.readdirSync(wp("desc")).filter(f => /^g\d+\.txt$/.test(f)).sort().map(f => wp("desc", f)) : [];
  for (const f of files) for (const l of fs.readFileSync(f, "utf8").split("\n").filter(x => x.trim())) { const k = l.indexOf(";"); const key = l.slice(0, k).trim(); if (!m.has(key)) m.set(key, l.slice(k + 1).trim()); }
  return m;
}
const saveDesc = m => fs.writeFileSync(wp("desc", "_all.txt"), [...m].map(([k, v]) => `${k};${v}`).join("\n") + "\n");
function widths(rows) {
  const kids = new Map();
  for (const r of rows) { const s = r.path.split("/"); for (let d = 1; d < s.length; d++) { const par = s.slice(0, d).join("/"); if (!kids.has(par)) kids.set(par, new Map()); const m = kids.get(par); const o = m.get(s[d]) || { n: 0, leaf: false }; o.n++; o.leaf = d === s.length - 1; m.set(s[d], o); } }
  return kids;
}
function cmdReshapeList() {
  const rows = treeRows(), kids = widths(rows);
  const wide = [...kids].filter(([, m]) => m.size > 9).map(([p, m]) => ({ path: p, n: m.size })).sort((a, b) => a.path.localeCompare(b.path));
  if (fs.existsSync(wp("reshape")) && fs.readdirSync(wp("reshape")).length) fs.renameSync(wp("reshape"), wp(`reshape-archive-${Date.now()}`));
  fs.mkdirSync(wp("reshape"), { recursive: true });
  fs.writeFileSync(wp("wide.json"), JSON.stringify(wide));
  console.log(JSON.stringify({ count: wide.length, worst: wide.slice().sort((a, b) => b.n - a.n).slice(0, 5) }));
}
const WIDE = () => readJ(wp("wide.json"));
function cmdReshapeCount() {
  const kids = widths(treeRows()), wide = [...kids].filter(([, m]) => m.size > 9);
  console.log(JSON.stringify({ count: wide.length, readOnly: true }));
}
function cmdReshapeInput() {
  const n = +pos[0], w = WIDE()[n - 1]; if (!w) die("no such wide branch");
  const rows = treeRows(), byStart = new Map(P().pieces.map(p => [P().files[p.f].rel + ":" + p.s, p])), ld = fs.existsSync(wp("leafdesc.json")) ? readJ(wp("leafdesc.json")) : {};
  const ch = new Map();
  for (const r of rows) { if (!r.path.startsWith(w.path + "/")) continue; const s = r.path.slice(w.path.length + 1).split("/"); const c = s[0]; if (!ch.has(c)) ch.set(c, { n: 0, sub: [], leaf: s.length === 1, sn: "" }); const o = ch.get(c); o.n++; if (s.length > 1) { o.leaf = false; if (o.sub.length < 3 && !o.sub.includes(s[1])) o.sub.push(s[1]); } else { const pc = byStart.get(r.range.slice(0, r.range.lastIndexOf("-"))); o.sn = ld[r.range] || (pc && pc.k !== "c" ? pc.sn.split(" ").slice(0, 14).join(" ") : ""); } }
  console.log(`TASK
The branch "${w.path}" of a specification outline has ${ch.size} children, too many to survey. Group them into 3 to 7 themed groups.
Write ONE LINE per child, exactly:    <Child Title exactly as shown>;<Group Title>;<description>
- Every child exactly once. All children of one group get the identical Group Title and description.
- Group Title: 2-4 words, Title Case, no ";" or "/" or quotes, different from every child title.
- description: one sentence, max 20 words, saying what the group covers.
- Each group should end up with 2-9 children; keep children of a group close in the original order where the theme allows.
Write the lines to ${path.relative(process.cwd(), wp("reshape", `r${n}.txt`))} with the Write tool, then run:
  node ${SELF} check-reshape ${n} --work ${SELFREL}   and fix the file until it prints OK. Reply with just "done".

CHILDREN of "${w.path}"
${[...ch].map(([c, o]) => `${c}   ${o.leaf ? "[piece] " + o.sn : `[branch, ${o.n} pieces] ${o.sub.join(", ")}`}`).join("\n")}`);
}
function readReshape(n) {
  const f = wp("reshape", `r${n}.txt`); if (!fs.existsSync(f)) return null;
  return fs.readFileSync(f, "utf8").split("\n").map(l => l.trim()).filter(Boolean).map(l => { const a = l.split(";"); return { child: a[0].trim(), group: (a[1] || "").trim(), desc: a.slice(2).join(";").trim() }; });
}
function cmdCheckReshape() {
  const n = +pos[0], w = WIDE()[n - 1], rows = readReshape(n); if (!rows) die(`ERROR: reshape file r${n}.txt not found`);
  const kids = widths(treeRows()).get(w.path), errs = [], seen = new Set(), groups = new Map();
  for (const r of rows) {
    if (!kids.has(r.child)) { errs.push(`unknown child "${r.child}"`); continue; }
    if (seen.has(r.child)) errs.push(`child "${r.child}" appears twice`); seen.add(r.child);
    if (!segsOk(r.group) || r.group.includes("/")) errs.push(`group title "${r.group}" must be 2-4 words without ; or /`);
    if (kids.has(r.group)) errs.push(`group title "${r.group}" equals an existing child title`);
    groups.set(r.group, (groups.get(r.group) || 0) + 1);
  }
  for (const c of kids.keys()) if (!seen.has(c)) errs.push(`child "${c}" missing`);
  if (groups.size < 2) errs.push("need at least 2 groups"); if (groups.size > 9) errs.push("at most 9 groups");
  if (errs.length) { console.log(errs.slice(0, 30).map(e => "ERROR: " + e).join("\n")); process.exit(1); }
  console.log("OK");
}
function cmdApplyReshape() {
  const rows = treeRows(), wide = WIDE(), desc = loadDesc(); let applied = 0, skipped = 0;
  const order = wide.map((w, i) => ({ ...w, n: i + 1 })).sort((a, b) => b.path.split("/").length - a.path.split("/").length);
  for (const w of order) {
    const rr = readReshape(w.n); if (!rr) { skipped++; continue; }
    const map = new Map(rr.map(r => [r.child, r.group]));
    for (const r of rows) if (r.path.startsWith(w.path + "/")) { const s = r.path.slice(w.path.length + 1).split("/"); const g = map.get(s[0]); if (g) r.path = [w.path, g, ...s].join("/"); }
    const nd = new Map();
    for (const [k, v] of desc) { if (k.startsWith(w.path + "/")) { const s = k.slice(w.path.length + 1).split("/"); const g = map.get(s[0]); nd.set(g ? [w.path, g, ...s].join("/") : k, v); } else nd.set(k, v); }
    desc.clear(); nd.forEach((v, k) => desc.set(k, v));
    for (const r of rr) if (r.desc && !desc.has(w.path + "/" + r.group)) desc.set(w.path + "/" + r.group, r.desc);
    applied++;
  }
  fs.writeFileSync(wp("tree.paths"), rows.map(r => `${r.g};${r.path};${r.range}`).join("\n") + "\n"); saveDesc(desc);
  if (applied) fs.writeFileSync(wp("reshape.applied"), "1");
  const still = [...widths(rows)].filter(([, m]) => m.size > 9).length;
  console.log(`OK  reshaped ${applied} branches${skipped ? `, ${skipped} had no result` : ""}; ${still} branches still wider than 9`);
}

function cmdGroupsArgs() {
  console.log(JSON.stringify({ work: path.relative(process.cwd(), WORK) || ".", cli: SELF, groups: GR().map(g => ({ g: g.g, windows: g.windows.length })) }));
}

/* ---------------- build ---------------- */
function cmdBuild() {
  const rows = treeRows(), desc = loadDesc();
  const ld = fs.existsSync(wp("leafdesc.json")) ? readJ(wp("leafdesc.json")) : {}, byRange = new Map(P().pieces.map(p => [`${P().files[p.f].rel}:${p.s}-${p.e}`, p]));
  const title = path.basename(P().root).replace(/[-_]+/g, " ").replace(/\b\w/g, c => c.toUpperCase());
  const root = { title, children: [] }; let id = 0;
  const lines = [];
  for (const r of rows) {
    const s = r.path.split("/"); let n = root, acc = [];
    s.forEach((seg, d) => {
      acc.push(seg);
      if (d < s.length - 1) { let c = n.children.find(x => x.title === seg && x.children); if (!c) { c = { title: seg, children: [] }; const dsc = desc.get(acc.join("/")); if (dsc) c.description = dsc; n.children.push(c); } n = c; }
      else { const [file, rg] = [r.range.slice(0, r.range.lastIndexOf(":")), r.range.slice(r.range.lastIndexOf(":") + 1)]; const [a, b] = rg.split("-").map(Number); const leaf = { title: seg, file, start: a, end: b }, pc = byRange.get(r.range); if (pc && pc.k === "c") { leaf.kind = "code"; leaf.lang = pc.lang; leaf.description = ld[r.range] || ""; } n.children.push(leaf); }
    });
  }
  const cache = {}; const lines_ = f => cache[f] ??= fs.readFileSync(path.join(P().root, f), "utf8").replace(/\r\n/g, "\n").split("\n");
  let stale = 0; const staleFiles = new Set();
  (function w(n) { n.id = "n" + id++; if (n.children) n.children.forEach(w); else { n.text = lines_(n.file).slice(n.start - 1, n.end).join("\n"); const pc = byRange.get(`${n.file}:${n.start}-${n.end}`); if (pc && pc.h && H(n.text) !== pc.h) { stale++; staleFiles.add(n.file); } } })(root);
  if (stale && !argv.includes("--allow-stale")) die(`ERROR: ${stale} piece(s) in ${staleFiles.size} file(s) changed since the split (${[...staleFiles].slice(0, 5).join(", ")}${staleFiles.size > 5 ? ", ..." : ""}). The titles and descriptions were written for the old text. Re-run split (and the agents) on the current files, or pass --allow-stale to build anyway.`);
  const out = path.resolve(opt("--out", "whitebox.json"));
  fs.writeFileSync(out, JSON.stringify({ version: 1, root: P().root, title, tree: root }));
  // find-style flat listing: group;path;file:start-end;description
  const flat = []; const gOf = new Map(rows.map(r => [r.path, r.g]));
  (function w(n, p) { const pp = n === root ? [] : [...p, n.title]; if (n !== root) flat.push([n.children ? "" : gOf.get(pp.join("/")) ?? "", pp.join("/"), n.children ? "" : `${n.file}:${n.start}-${n.end}`, n.description || ""].join(";")); if (n.children) n.children.forEach(c => w(c, pp)); })(root, []);
  fs.writeFileSync(out.replace(/\.json$/, "") + ".paths", flat.join("\n") + "\n");
  console.log(`wrote ${out} (+ .paths): ${id} nodes, ${desc.size} descriptions`);
}

const CMDS = { split: cmdSplit, window: cmdWindow, check: cmdCheck, "merge-input": cmdMergeInput, "apply-merge": cmdApplyMerge, "describe-input": cmdDescribeInput, "check-desc": cmdCheckDesc, build: cmdBuild, status, "check-all": cmdCheckAll, "groups-args": cmdGroupsArgs, "reshape-list": cmdReshapeList, "reshape-count": cmdReshapeCount, estimate: cmdEstimate, "reshape-input": cmdReshapeInput, "check-reshape": cmdCheckReshape, "apply-reshape": cmdApplyReshape };
if (!CMDS[cmd]) die("unknown command " + cmd); CMDS[cmd]();
