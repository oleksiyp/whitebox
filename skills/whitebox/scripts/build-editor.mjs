// node tools/build-editor.mjs [whitebox.json] [out.html]  -> self-contained editor with the tree embedded
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";
const [src = "whitebox.json", out = "whitebox.html"] = process.argv.slice(2);
const json = JSON.stringify(JSON.parse(readFileSync(src, "utf8"))).replace(/</g, "\\u003c");
const here = dirname(fileURLToPath(import.meta.url));
const applyCmd = "node " + relative(process.cwd(), join(here, "apply-edits.mjs"));
writeFileSync(out, readFileSync(join(here, "editor.template.html"), "utf8").replace("__APPLY_CMD__", () => applyCmd).replace("__TREE__", () => json));
console.log("wrote", out);
