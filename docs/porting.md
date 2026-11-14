# Porting whitebox: shell (POSIX sh + awk) and PowerShell

The Node implementation (`skills/whitebox/scripts/*.mjs`) is the **reference**. The ports exist so that whitebox runs with
nothing to install: `sh` + `awk` on macOS/Linux, PowerShell on Windows. A port is correct when it is *indistinguishable* from the
reference: same arguments, same printed messages, same exit codes, same files.

## Deliverables

Same four tools, same names, different extension, in `skills/whitebox/scripts/`:

| Reference | Shell port | PowerShell port |
|---|---|---|
| `whitebox.mjs` | `whitebox.sh` | `whitebox.ps1` |
| `apply-edits.mjs` | `apply-edits.sh` | `apply-edits.ps1` |
| `validate.mjs` | `validate.sh` | `validate.ps1` |
| `build-editor.mjs` | `build-editor.sh` | `build-editor.ps1` |

Helper files are allowed (`scripts/lib/*.awk`, `scripts/lib/*.ps1`) but the four entry points must work when invoked by absolute
path from any directory, with no installation step. `editor.template.html` is shared by all implementations and must not change.

Every subcommand of `whitebox.mjs` must be ported: `split window check check-all status groups-args estimate merge-input apply-merge
describe-input check-desc reshape-count reshape-list reshape-input check-reshape apply-reshape build`. The arguments, flags
(`--work --out --window --max-kb --include --exclude --tests --config --allow-stale --force --drop-excluded --dry-run --root`) and
defaults are identical.

## Acceptance (all must pass, nothing weakened)

The same test suite runs against every implementation; `WHITEBOX_IMPL` selects it (see `test/helpers.mjs` for all knobs).

```sh
# the 30 functional tests, against the port
WHITEBOX_IMPL=sh  npm test                               # shell port
WHITEBOX_IMPL=ps  WHITEBOX_PWSH=pwsh npm test            # PowerShell port
# differential tests: the port vs the Node reference on identical inputs (messages, work files, JSON, HTML, bytes written back)
WHITEBOX_PARITY=sh  node --test test/parity.test.mjs
WHITEBOX_PARITY=ps  WHITEBOX_PWSH=pwsh node --test test/parity.test.mjs
WHITEBOX_PARITY_SEEDS=25 ...                             # more random projects (default 6)
```

Run them on every target environment:

| Port | Environments |
|---|---|
| sh | macOS host (`/bin/sh` is bash 3.2 in POSIX mode, BSD awk); `debian:bookworm-slim` (dash + mawk); `alpine` (busybox sh + busybox awk) |
| ps | PowerShell 7 (`mcr.microsoft.com/powershell`) in a container; and the code must be valid for **Windows PowerShell 5.1** (CI runs it) |

Containers: the harness stays on the host and the port runs inside a container through `WHITEBOX_PREFIX`. Mount `/tmp` and the repo at
the *same absolute paths* so that paths mean the same thing on both sides, and use an image that has `git` (build small derived
images in `test/docker/`: base + `git` + nothing else, e.g. `FROM debian:bookworm-slim` + `apt-get install -y --no-install-recommends git`):

```sh
export WHITEBOX_PREFIX="docker run --rm -i -v /tmp:/tmp -v $PWD:$PWD -w /tmp wb-debian"   # one container per call; or a long-lived one with 'docker exec'
WHITEBOX_IMPL=sh WHITEBOX_SH=dash WHITEBOX_PARITY= npm test
```
(Images already present: `debian:bookworm-slim`, `alpine:latest`, `mcr.microsoft.com/powershell:latest`. Do not pull anything else.)

## Rules for the shell port

It must run on a clean macOS or Linux machine with only the base system.

- **POSIX `sh` only.** No `[[ ]]`, no arrays, no `local`-dependence you cannot prove on dash+busybox+bash3, no `echo -e`, no process
  substitution, no `$'...'`, no `${var//x/y}`, no `declare`. Prefer `printf`.
- **POSIX `awk` only**, and it must run on BWK awk (macOS), mawk (Debian) and busybox awk. No gawk extensions (`gensub`, `asort`, `strftime`, `systime`,
  `\<` `\>`, `PROCINFO`, `RT`, `FPAT`, `BEGINFILE`), **no regex interval expressions `{n,m}`** (mawk/old awks differ; spell them out), no `\s \w \d \b`
  (use bracket classes), no `length(array)`, no `printf("%c")` tricks beyond ASCII, no `getline < "-"` surprises. Run everything under `LC_ALL=C` so awk and sort see bytes.
- **No dependencies beyond the base system:** `sh awk sed grep sort cut tr head tail wc cat cp mv rm mkdir mktemp od dd printf`, plus `git` when present
  (file selection falls back to a directory walk when it is not) and one of `sha1sum` / `shasum -a 1` / `openssl sha1` (detect, in that order).
  **Not allowed:** `jq`, `python`, `perl`, `node`, `ruby`, `bash`, GNU-only flags (`sed -i` without a backup suffix argument differs between BSD and GNU - avoid `-i`,
  write to a temp file and `mv`; avoid `sed -r`, use `-E`; avoid `readlink -f`, `date -d`, `sort -V`, `xargs -d`, `find -printf`, `grep -P`).
- JSON: you need to *write* JSON (compact, exact escaping: `"` `\` `\b \f \n \r \t`, other control chars as `\u00XX`, everything else raw UTF-8) and to
  *read* JSON (`pieces.json`, `groups.json`, `wide.json`, `leafdesc.json`, `estimate.json`; the editor's `whitebox-edits.json`; `whitebox.json`). Write a small, tested
  awk JSON reader (flatten to `path<TAB>value` lines) once and reuse it. `pieces.json` is written one record per line precisely so that it is cheap to read.
- Speed: `split` on a 14,000-piece project must finish in under about a minute; individual agent-facing commands (`window`, `check`) in a few seconds.
  Avoid one process per line/piece; do the work inside a few awk programs.

## Rules for the PowerShell port

- Must run on **Windows PowerShell 5.1 and PowerShell 7**: no `?.` `??` `?:`, no `&&`/`||`, no `ForEach-Object -Parallel`, no `$IsWindows`-only logic, `Join-Path` with
  two arguments only, no `-AsHashtable`, no `Get-Content -Raw` surprises with BOM (read bytes and decode explicitly).
- **Encoding:** read and write UTF-8 **without BOM** through `[System.IO.File]` and `New-Object System.Text.UTF8Encoding($false)`; never `Set-Content`/`Out-File`
  (they add a BOM or UTF-16 on 5.1). Console output: set `[Console]::OutputEncoding` to UTF-8 without BOM and write `\n` line endings only (use `[Console]::Out.Write`).
- Write JSON by hand (compact, same escaping and key order as the reference); `ConvertTo-Json` differs between 5.1 and 7 and unrolls single-element arrays. Reading with
  `ConvertFrom-Json` is fine but beware 5.1's single-element array unrolling and its depth/size limits; for large files prefer a small streaming parse or the one-record-per-line layout of `pieces.json`.
- Speed: PowerShell loops are slow. Use .NET (`[regex]`, `System.Text.StringBuilder`, `System.Collections.Generic.List/Dictionary`, `[System.IO.File]::ReadAllLines`) in hot paths.
  Compiling C# with `Add-Type` is **not** allowed (constrained-language environments).
- Exit codes and stderr/stdout split must match the reference (the harness merges them, but exit codes are asserted).
- No dependencies: no modules, no `git` requirement beyond what the reference has (`git ls-files`; fall back to a walk when git is absent).

## Details that are easy to get wrong (the reference is deliberately deterministic)

1. **Whitespace is ASCII only** (`space \t \r \n \f \v`): trimming, word counting (`W`), blank-line tests, `\s`-like classes. Unicode spaces (NBSP, U+2028, ...) are *not* whitespace.
2. **Sorting is bytewise** on the UTF-8 bytes (`LC_ALL=C sort`, `[string]::CompareOrdinal` on UTF-8-equivalent), **lower-casing is ASCII-only**.
3. A **leading UTF-8 BOM** on the first line is ignored when classifying that line (heading, fence, declaration) but stays in the verbatim piece text.
4. **Line endings:** files are split on `\n` after replacing `\r\n`; a final empty element from a trailing newline is dropped. `apply-edits` preserves CRLF files exactly (all `\n` become `\r\n` iff the original contained `\r\n`).
5. **Tie-breaking and insertion order matter:** the skip report sorts by count descending, ties in first-seen order; sample lists keep the first three seen; `Set`/`Map` order is insertion order.
6. **Numbers:** `estimate` uses `Math.round` (half up) for agents and minutes and integer tenths for tokens (`floor((agents*6+5)/10)/10`); print `tokensM` as one decimal only when needed exactly as JS prints a number (`1` not `1.0`, `0.6`).
7. **Paths printed for agents are absolute and quoted only if they contain special characters** (`q()` in the reference). The launcher word differs per port (`node X.mjs` / `sh X.sh` / `pwsh -File X.ps1`): print your own correct invocation; the harness masks that part only.
8. `pieces.json` layout (one record per line), key order inside records and `files[].h` (sha1 of the raw file bytes) are part of the contract (`references/formats.md`).
9. Messages are the contract: tests and agents match on them (`ERROR:`, `OK`, `CONFLICT ...`, `changed since the split`, `already applied`...). Copy them exactly.
10. `git ls-files -co --exclude-standard -z` is the primary file list; paths with spaces and non-ASCII characters must survive. Without git, walk the tree skipping `.`-prefixed entries and `node_modules`.
11. Binary detection is "a NUL byte in the first 4096 bytes"; the generated-code check looks at the first 6 lines (600 bytes) for the reference's regex (case-insensitive).
12. The code segmenter's heuristics (bracket depth with strings/comments stripped, column-0 declaration starts, comment/decorator attachment, blank-line splitting) are *bug-compatible*: the parity tests use random code in nine languages.

## Working rules

- **Do not edit the reference** (`*.mjs`), `editor.template.html` or the existing tests. If the reference does something unportable or ambiguous, write the question and your proposal in
  `docs/porting-notes.md` (section per issue) and make the port follow the reference until the maintainer decides. You may add port-specific tests as `test/<impl>-extra.test.mjs`.
- Build in stages and run the parity tests after each: (1) `split` + file selection + both segmenters (pieces.json, groups.json, estimate.json, selection.json, stdout), (2) `window check check-all status
  groups-args estimate merge-input describe-input check-desc reshape-*`, (3) `apply-merge build validate build-editor apply-edits`.
- Lint: `shellcheck -s sh` must pass on the shell port (it is installed); for PowerShell run `Invoke-ScriptAnalyzer` if you can get it without a download, otherwise review by hand.
- Keep the code readable: sections mirroring the reference, comments only where behaviour is non-obvious.

## Definition of done

Report the exact commands run and their results for every environment, the number of seeds run (at least 25 for the final parity run), measured timings of `split` on the 14k-piece synthetic project
(`test/stress.mjs` can generate one), anything left unported, and every entry in `docs/porting-notes.md`.
