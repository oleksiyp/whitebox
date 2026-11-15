# Porting notes: shell port (POSIX sh + awk)

Scope: `skills/whitebox/scripts/{whitebox,apply-edits,validate,build-editor}.sh` and `scripts/lib/*` (awk programs, templates of the
agent prompts). Reference: the `.mjs` files. Nothing in the reference, `editor.template.html` or the existing tests was changed.

## How it is built

| Piece | Role |
|---|---|
| `whitebox.sh` | argument parsing (same rules as the reference), `git ls-files -z` / `find` file list, picks the awk program |
| `lib/split.awk` | file selection (with the skip report), both segmenters, groups/windows, estimate; writes `pieces.json groups.json estimate.json selection.json` |
| `lib/wb.awk` | all other subcommands (`window check ... build`); prompt texts live in `lib/tpl/*.txt` with `@NAME@` placeholders |
| `lib/json.awk` | JSON reader (flat `J[path]` table) and the compact re-serialiser used by `build-editor` |
| `lib/common.awk`, `lib/bytes.awk` | JSON escaping, UTF-8/UTF-16 helpers, path helpers (`path.resolve/relative` equivalents), `slurp` |
| `lib/validate.awk`, `lib/applyedits.awk`, `lib/buildeditor.awk` | the three other tools |

Everything runs under `LC_ALL=C` (set by the scripts, so the caller's locale does not matter; checked by `test/sh-extra.test.mjs`).
Tools used: `sh awk sed sort tr head wc cp mv rm mkdir mktemp ls find dirname date test git sha1sum|shasum|openssl` (`find`, `ls`, `date`,
`dirname`, `test` are the only ones outside the list in `porting.md`; `find` is needed for the no-git walk). `sh-extra.test.mjs` runs the pipeline with a
`PATH` that contains exactly these tools.
awk portability was checked on BWK awk 20200816 (macOS), mawk 1.3.4 (Debian) and busybox awk 1.37 (Alpine). Things that bit and are avoided:
`function q` vs a local named `q` (mawk), `substr()` on a huge string being O(length) on BWK awk (JSON is therefore read with `RS=","`, never as one 10 MB line),
`-f file` cannot be combined with an inline program text, awk's 50-parameter limit (BWK) for one function.

## Reference changes followed

`TEST_RE` (per-alternative `$`, test directories skipped), ASCII-only whitespace in `validate.mjs`, and the empty-selection error (`split` exits 1 after the selection report, `selection.json` is written, `pieces.json` is not) are ported. The editor-command assertion in `pipeline.test.mjs` now accepts `.sh`.

## Known differences / not ported (all outside what the tests and parity suites generate)

* **Lone UTF-16 surrogates.** The reference cuts code snippets with `slice(0,100)` in UTF-16 units; the port counts units correctly (BMP = 1, astral = 2) but
  when the cut would fall inside an astral character it drops the character instead of emitting a lone surrogate (`\ud83d`).
* **Invalid UTF-8** in a source file: Node decodes with U+FFFD replacement (so `bytes` and the text differ); the port keeps the raw bytes.
* **NUL bytes** beyond the first 4096 bytes and `\u0000` in JSON input cannot be represented in awk strings.
* **Lone `\r`** inside a code line: JS `.` does not match `\r`/U+2028/U+2029, so a `// comment` followed by a lone `\r` is not stripped by the reference's bracket counter;
  the port strips it (CRLF files are normalised before, so this only matters for stray `\r`).
* **File names containing a newline** (the list is newline-separated after `git ls-files -z`).
* `build-editor` normalises integers and `-0`; other number spellings (`1.0`, `1e2`) and duplicate object keys are copied verbatim instead of going through
  `JSON.parse/stringify`. Malformed JSON is not rejected (Node throws).
* Where Node would crash with a stack trace (missing files, `L[n]` undefined in `validate`, ...) the port prints a one-line error to stderr and exits 1 (same exit code).
* `apply-edits` usage line says `apply-edits.sh`.
* `reshape-list` archives an existing `reshape/` directory as `reshape-archive-<epoch seconds>000` (millisecond part is zero).
* `git` is called with `-c safe.directory=*` so that repositories owned by another user (bind mounts in containers) are still listed, as they are for Node on the host.
  Without git (or when `git ls-files` fails) a `find` walk is used, sorted bytewise; the reference uses directory order, which only influences the *sample* paths in the skip report.

## Testing notes

* `WHITEBOX_PREFIX` containers need the repo and `/tmp` at the same paths, and on macOS `/tmp` is `/private/tmp`. `test/docker/run.sh` mounts both and passes the
  caller's cwd (`docker run -w` alone cannot, because the harness gives every call a different cwd); run the host side with `TMPDIR=/tmp`.
  `--exec NAME` uses a long-lived container (`docker exec`), which makes a parity run ~10x faster.
* `test/docker/debian.Dockerfile` / `alpine.Dockerfile` build `wb-debian` and `wb-alpine` (base image + `git`).
* Docker Desktop bind mounts (macOS) return **stale file sizes/contents for a file that was just overwritten in place from the host** when it is read through a
  long-lived container (`docker exec`): 26 of 40 write-then-read probes were stale. The parity test "check and validate reject the same malformed agent output"
  rewrites the same `out/gN-wM.txt` file seven times, so it failed 1 run in 3 in `--exec` mode (the port saw a truncated file) and passes reliably with one
  container per call (`run.sh IMAGE`, no `--exec`). Use per-call containers for that test; `--exec` is fine for the seed tests.

## Measured (macOS arm64, 12,438 pieces in 2,400 files, 48 groups; `randomProject(5, 2400)`)

| | macOS (BWK awk) | debian (mawk) | alpine (busybox) |
|---|---|---|---|
| `split` | 14-25 s | 3.5 s | 5.6 s |

macOS is slower mostly because of process creation: `split` starts a few helper processes per candidate file (size, NUL probe, sha1).
Agent-facing commands on the same project (macOS): `window` 0.31 s, `check` 0.32 s, `check-all` (76 windows) 0.9 s, `status` 0.09 s, `merge-input` 0.11 s,
`apply-merge` 0.6 s, `build` 10 s (one `sha1` per file), `validate` 2.2 s, `build-editor` 1.3 s. At that scale `pieces.json`, `tree.paths`, `whitebox.json` and `whitebox.paths` are
byte-identical to the Node reference and `validate` prints the same text.
