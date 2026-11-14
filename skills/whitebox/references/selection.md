# File selection

`whitebox.mjs split <dir>` decides which files are analysed. The goal: the files that carry meaning, not the
files that merely exist.

**Source of the list.** Inside a git repository: `git ls-files -co --exclude-standard`, i.e. tracked plus untracked
files, honouring `.gitignore`. Otherwise a directory walk. A list of files instead of a directory is taken as given.

**Always skipped** (each skip is counted and printed with examples):

| Reason | Examples |
|---|---|
| hidden file or directory | `.env`, `.github/`, `.cache/` |
| generated / vendored / fixture dirs | `node_modules vendor dist build out target coverage testdata fixtures golden generated third_party __snapshots__` |
| secret-looking files | `.env*`, `*.pem *.key id_rsa* *.tfstate *.tfvars`, `*secret*.json`, `.npmrc` |
| lockfiles | `go.sum package-lock.json yarn.lock Cargo.lock` |
| minified / sourcemaps | `*.min.js *.map` |
| binaries / media / unknown types | images, archives, databases |
| generated code | header contains `Code generated`, `DO NOT EDIT`, `@generated` |
| big source files | over `--max-kb` (default 300); markdown has an 8 MB cap |

**Off by default, opt in:** test files (`--tests`: `*_test.go`, `*.test.ts`, `tests/`, ...) and config files
(`--config`: yaml, json, toml, xml, tf, ini).

**Included:** markdown, and source in go ts tsx js jsx py rs java kt c cpp cs rb php swift sh sql proto star lua scala ex dart.

**Flags:** `--include "a/**,b/*.md"` forces files in (also overrides the filters above); `--exclude "ui/**"` removes
files. Globs: `*` within a directory, `**` across directories.

**How pieces are cut.** Markdown: by heading, list item, table, fenced block, paragraph; small neighbours are merged
up to about 80 words and big blocks split at line boundaries. Code: at top-level declarations (leading comments and
decorators stay with their declaration), small ones merged, long ones split at blank lines, about 200 words per piece.
Every non-blank line belongs to exactly one piece, which is what makes write-back safe.
