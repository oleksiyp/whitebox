# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning: [SemVer](https://semver.org/).

## [0.1.0] - unreleased
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
