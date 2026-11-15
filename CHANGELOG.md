# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning: [SemVer](https://semver.org/).

## [0.4.0] - 2026-11-15
### Added
- Optional per-phase model choice: workflow args `"models": {"merge": "opus"}` (default Haiku everywhere). The skill offers an Opus merge at the go/no-go question.

## [0.3.0] - 2026-11-15
### Added
- **POSIX `sh` + `awk` and PowerShell ports** of all four tools (`whitebox`, `apply-edits`, `validate`, `build-editor`), so whitebox runs with nothing
  to install: macOS/Linux with only the base system, Windows with the PowerShell that ships with it. The skill picks Node, else `sh`, else PowerShell.
  Each port is held identical to the Node reference by the same test suite plus differential parity tests on random projects (printed messages, work files,
  JSON, editor page, bytes written back). CI runs them on Ubuntu (dash), macOS (BSD awk), Debian (dash + mawk), Alpine (busybox) and on real Windows
  (Windows PowerShell 5.1 and PowerShell 7); the Node reference also runs on Windows.
- `groups-args` prints `run` (the full launcher command) and the workflows use it instead of hard-coding `node`.
- `.gitattributes` keeps LF line endings in Windows checkouts.

### Changed
- **Nothing is written into the user's project or the current directory.** `--work DIR` is now required (no implicit `.whitebox` folder), `build` writes into the
  work directory by default, and `build-editor` requires both file arguments. The skill keeps scratch files in Claude's scratchpad and publishes the result as a
  private **Artifact**; `build-editor --artifact --title NAME` writes the fragment the Artifact tool wraps. Inside an artifact the page saves exports through the
  `downloads` capability (a sandboxed page cannot start downloads) and offers *Send edits to Claude* through the `db` capability, so write-back needs no file
  in the project or in Downloads.
- Paths printed for agents (and the `work` / `cli` fields of `groups-args`) use `/` on every OS and are quoted only when they contain whitespace or shell-special
  characters. A bare `\` path is eaten by Git Bash; `/` works in Git Bash, PowerShell, cmd, Node and .NET.

### Fixed
- The PowerShell port's page builder did not escape `<` in the embedded tree (a spec containing `</script>` would have broken the page); parity tests now include such text.
- Windows: relative file names inside `pieces.json`, the tree and messages used backslashes (`docs\guide.md`); they always use `/` now.
- Test directories (`tests/`, `test/`, `__tests__/`, `e2e/`) were never skipped by default because of a regex precedence slip; only test *file names* were.
- `validate` trimmed Unicode whitespace, unlike the rest of the tool; it is ASCII-only now.
- `split` on a selection that contains no pieces printed `~-Infinity min` and wrote empty work files; it now stops with `ERROR: nothing to analyse`.

### Known limits of the ports
- Edge cases outside what the tests generate are documented in `docs/porting-notes-sh.md` and `docs/porting-notes-ps.md` (invalid UTF-8, lone UTF-16 surrogates, file names
  containing a newline). Where the reference would crash with a stack trace, the ports print a one-line error with the same exit code.
- The `sh` port is slower than Node on macOS (`split` took 14-25 s on a 12,000-piece project, against about 0.4 s for Node).

## [0.2.0] - 2026-11-14
### Fixed
- A UTF-8 byte order mark at the start of a file (common for files created on Windows) hid a first-line heading or code fence.
  That misaligned every later fence and split pieces inside code blocks. Found by the new random-project stress test.
- Agents could fail when their working directory differed from the one the work files were created in (relative paths, e.g.
  `check` reporting "not found" for an output file that had just been written). Every path printed for agents is now absolute,
  and quoted when it contains special characters.

### Changed
- The skill keeps work files in Claude's scratchpad when one is available (otherwise `.whitebox-<project>` in the current
  directory) and writes the finished `whitebox-<project>.json/.html/.paths` to the current directory. `workflow.js` is copied
  into the work directory before it is run.
- The "source changed after the split" check hashes each file (sha1 of the raw bytes, stored in `pieces.json`) instead of each
  piece: any edit to a file invalidates its line ranges anyway, and a per-file hash needs one tool call per file in every language.
- The reference implementation is deterministic across machines: ASCII-only whitespace, trimming and lower-casing, bytewise sorting,
  and an integer-only token estimate (the printed estimate may differ from 0.1.0 in the last digit).
- `pieces.json` is written one record per line (still plain JSON).

### Added
- A test harness that can run the whole suite against any implementation (`WHITEBOX_IMPL=node|sh|ps`, optional container prefix),
  seeded random-project stress tests, and differential parity tests that compare an implementation with the Node reference on
  identical inputs (messages, work files, JSON, editor page, bytes written back).
- `docs/porting.md`: the contract for POSIX shell and PowerShell ports. The ports themselves are not part of this release.

## [0.1.0] - 2026-11-14
### Added
- Skill `whitebox`: split a project (markdown + source code) into pieces with exact line ranges, have Haiku agents
  outline, merge, describe and reshape them into one tree, review it in a self-contained HTML editor.
- Whole-project file selection: git-aware (`.gitignore`), skips hidden/vendored/generated/test/config/secret files,
  with a printed report and `--tests --config --include --exclude --max-kb` flags.
- Code-to-specification descriptions for source pieces; code is never written back.
- Verified markdown write-back (`apply-edits.mjs`) with dry run, conflict detection and CRLF preservation.
- Cost estimate printed after `split` (calibrated on four real runs).
- Integrity: every piece stores a hash of its text at split time; `build` refuses to run if the source changed since.
- Claude Code plugin and marketplace manifests.
