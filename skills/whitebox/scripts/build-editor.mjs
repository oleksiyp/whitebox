// node build-editor.mjs <whitebox.json> <out.html> [--title "Name"] [--artifact]
//   self-contained editor with the tree embedded. --artifact drops the document wrapper (doctype/html/head/body) because the Artifact
//   tool adds its own skeleton; --title sets <title>. Both file arguments are required: nothing is ever written to an implicit place.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";
const argv = process.argv.slice(2);
const pos = argv.filter((a, i) => !a.startsWith("--") && argv[i - 1] !== "--title");
const title = argv.includes("--title") ? argv[argv.indexOf("--title") + 1] ?? "" : null;
if (pos.length < 2) { console.error('usage: build-editor <whitebox.json> <out.html> [--title "Name"] [--artifact]'); process.exit(2); }
const [src, out] = pos;
const WRAP = new Set(["<!doctype html>", '<html lang="en">', "<head>", '<meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">', "</head>", "<body>", "</body>", "</html>"]);
const json = JSON.stringify(JSON.parse(readFileSync(src, "utf8"))).replace(/</g, "\\u003c");
const here = dirname(fileURLToPath(import.meta.url));
const applyCmd = "node " + relative(process.cwd(), join(here, "apply-edits.mjs"));
let html = readFileSync(join(here, "editor.template.html"), "utf8");
if (title) html = html.replace("<title>Whitebox</title>", () => "<title>" + title.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") + "</title>");
if (argv.includes("--artifact")) html = html.split("\n").filter(l => !WRAP.has(l)).join("\n");
writeFileSync(out, html.replace("__APPLY_CMD__", () => applyCmd).replace("__TREE__", () => json));
console.log("wrote", out);
