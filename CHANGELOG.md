# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning: [SemVer](https://semver.org/).

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
