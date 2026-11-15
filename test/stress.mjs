// Seeded random project generator used by the parity tests: same seed, same files, on every machine.
export function rng(seed) { let s = seed >>> 0; return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296); }
const pick = (r, a) => a[Math.floor(r() * a.length)];
const int = (r, lo, hi) => lo + Math.floor(r() * (hi - lo + 1));
const WORDS = ["alpha", "beta", "gamma", "delta", "token", "queue", "ledger", "plan", "apply", "rule", "owner", "cache", "stream", "épée", "naïve", "über", "日本語", "✔", "—", "x1", "R-042", "`code`", "**bold**", "_it_", "[link](http://x.y/z)", "a|b", "{brace}", "}", "(", ")", "//", "#hash", "\"q\"", "'s'", "C:\\path", "</script>", "<!--", "<b>x</b>", "&amp;"];
const sent = (r, n) => Array.from({ length: n }, () => pick(r, WORDS)).join(" ");

export function mdFile(r) {
  const out = [];
  const blocks = int(r, 3, 14);
  for (let b = 0; b < blocks; b++) {
    const k = pick(r, ["h", "p", "ul", "ol", "table", "fence", "quote", "ul", "p", "hr", "html", "longlist", "tabs"]);
    if (k === "h") out.push("#".repeat(int(r, 1, 4)) + " " + sent(r, int(r, 1, 5)) + (r() < 0.2 ? " ##" : ""));
    else if (k === "p") out.push(Array.from({ length: int(r, 1, 4) }, () => sent(r, int(r, 3, 14))).join("\n"));
    else if (k === "ul" || k === "ol") {
      const items = int(r, 1, 6), L = [];
      for (let i = 0; i < items; i++) {
        L.push((k === "ul" ? pick(r, ["-", "*", "+"]) : `${i + 1}${pick(r, [".", ")"])}`) + " " + sent(r, int(r, 2, 12)));
        for (let j = int(r, 0, 3); j > 0; j--) L.push(" ".repeat(pick(r, [2, 3, 4])) + pick(r, ["-", "*", "1."]) + " " + sent(r, int(r, 2, 8)));
        if (r() < 0.3) L.push("  " + sent(r, int(r, 2, 8)));
        if (r() < 0.15) L.push("");
      }
      out.push(L.join("\n"));
    } else if (k === "table") {
      const cols = int(r, 2, 4), rows = int(r, 1, 6);
      const row = () => "| " + Array.from({ length: cols }, () => sent(r, int(r, 1, 3))).join(" | ") + " |";
      out.push([row(), "|" + "---|".repeat(cols), ...Array.from({ length: rows }, row)].join("\n"));
    } else if (k === "fence") {
      const f = pick(r, ["```", "~~~", "````"]);
      out.push([f + pick(r, ["", "js", "go"]), ...Array.from({ length: int(r, 1, 6) }, () => (r() < 0.2 ? "" : sent(r, int(r, 1, 8)))), f].join("\n"));
    } else if (k === "quote") out.push(Array.from({ length: int(r, 1, 3) }, () => "> " + sent(r, int(r, 2, 9))).join("\n"));
    else if (k === "hr") out.push(pick(r, ["---", "***", "___", "- - -"]));
    else if (k === "html") out.push("<!-- " + sent(r, 3) + " -->");
    else if (k === "longlist") out.push(Array.from({ length: int(r, 12, 30) }, () => "- " + sent(r, int(r, 6, 12))).join("\n"));
    else out.push("\t" + sent(r, 4) + "\n\t\t" + sent(r, 3));
    out.push(...Array(pick(r, [0, 1, 1, 1, 2, 3])).fill(""));
  }
  let t = out.join("\n");
  t = t.replace(/\n{4,}/g, "\n\n\n");
  if (r() < 0.2) t = t.replace(/\n/g, "\r\n");
  if (r() < 0.3) t = t.replace(/\n+$/, "");
  else if (r() < 0.5) t += "\n";
  if (r() < 0.1) t = "\ufeff" + t;
  return t;
}

const ident = r => pick(r, ["Load", "Save", "Apply", "parse", "render", "Resolve", "handle_it", "buildTree", "Run", "check"]) + int(r, 1, 99);
const body = (r, ind, n, style) => Array.from({ length: n }, () => ind + pick(r, [
  `x := ${ident(r)}("a}", '{', \`}\`) // trailing { comment`, `if err != nil { return err }`, `// }`, `/* { */ y = ${int(r, 1, 99)}`,
  `s = "multi { word } string // not a comment"`, `call(${sent(r, 3).replace(/[`"']/g, "")})`, "", `\tdeep();`, `for i in range(3):`, `return ${int(r, 0, 9)}`,
])).join("\n");

export const CODE_LANGS = ["go", "py", "js", "ts", "rs", "java", "c", "sh", "sql"];
export function codeFile(r, lang) {
  const out = [];
  const units = int(r, 2, 9);
  if (lang === "go") out.push("package " + pick(r, ["main", "util", "store"]), "", "import (", '\t"fmt"', '\t"os"', ")", "");
  if (lang === "py") out.push("import os", "import sys", "", "");
  if (lang === "c") out.push("#include <stdio.h>", "#define X 1", "");
  for (let u = 0; u < units; u++) {
    const name = ident(r), doc = r() < 0.6;
    if (lang === "go") {
      if (doc) out.push(`// ${name} ${sent(r, int(r, 3, 9)).replace(/[`]/g, "")}`);
      out.push(pick(r, [`func ${name}(a int, b string) error {`, `type ${name} struct {`, `var ${name} = []string{`, `func (s *T) ${name}() {`]));
      out.push(body(r, "\t", int(r, 1, 25)));
      if (r() < 0.3) out.push("", body(r, "\t", 2));
      out.push("}");
    } else if (lang === "py") {
      if (r() < 0.4) out.push("@decorator(" + int(r, 1, 9) + ")");
      out.push(pick(r, [`def ${name}(x, y):`, `class ${name}:`, `async def ${name}():`]));
      if (r() < 0.5) out.push(`    """${sent(r, 6).replace(/"/g, "")}"""`);
      out.push(body(r, "    ", int(r, 1, 20)));
      if (r() < 0.3) out.push("", "    " + `def inner(self): return ${int(r, 1, 9)}`);
      if (r() < 0.2) out.push("if __name__ == '__main__':", "    pass");
    } else if (lang === "sh") {
      out.push((doc ? `# ${sent(r, 4)}\n` : "") + `${name}() {`, body(r, "  ", int(r, 1, 10)), "}");
    } else if (lang === "sql") {
      out.push(`${doc ? "-- " + sent(r, 4) + "\n" : ""}CREATE TABLE ${name} (`, ...Array.from({ length: int(r, 1, 6) }, (_, i) => `  c${i} TEXT,`), ");");
    } else {
      if (doc) out.push(pick(r, [`/** ${sent(r, 6)} */`, `// ${sent(r, 5)}`, `/*\n * ${sent(r, 5)}\n */`]));
      out.push(pick(r, [`export function ${name}(a, b) {`, `fn ${name}() {`, `public class ${name} {`, `static int ${name}(void) {`, `const ${name} = {`, `export const ${name} = () => {`, `impl ${name} {`]));
      out.push(body(r, "  ", int(r, 1, 25)));
      out.push(pick(r, ["}", "};", "});"]));
    }
    out.push(...Array(pick(r, [0, 1, 1, 2, 3])).fill(""));
  }
  let t = out.join("\n").replace(/\n{4,}/g, "\n\n\n");
  if (r() < 0.15) t = t.replace(/\n/g, "\r\n");
  if (r() < 0.3) t = t.replace(/\n+$/, ""); else t += "\n";
  return t;
}

/** a project of ~files random files; deterministic for a given seed */
export function randomProject(seed, files = 14) {
  const r = rng(seed), f = {};
  for (let i = 0; i < files; i++) {
    const dir = pick(r, ["", "docs/", "src/", "src/core/", "lib/a b/", "ünï/"]);
    if (r() < 0.5) f[`${dir}doc${i}${pick(r, ["", "-2", "-3"])}.md`] = mdFile(r);
    else { const lang = pick(r, CODE_LANGS); f[`${dir}code${i}.${lang}`] = codeFile(r, lang); }
  }
  return f;
}
