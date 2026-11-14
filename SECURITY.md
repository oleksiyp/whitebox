# Security and privacy

## Data flow
whitebox runs locally, but the model-written parts (titles, groupings, descriptions) are produced by Claude Haiku
subagents started through Claude Code. **The text of every selected file is therefore sent to the model provider**,
exactly as if you had asked Claude Code to read those files. Review the selection summary that `whitebox.mjs split`
prints before approving a run; the skill asks you to confirm it.

By default the selection skips files that are git-ignored, hidden, vendored, generated, lockfiles, binaries, and
files that look like secrets (`.env*`, `*.pem`, `*.key`, `id_rsa*`, `*.tfstate`, `*.tfvars`, `*secret*.json`, ...).
This is a heuristic, not a guarantee: a secret pasted into a source or markdown file will not be detected. If a
repository contains such content, exclude those paths (`--exclude`) or do not run whitebox on it.

## Writes
- Nothing is written into the analysed project unless you run `apply-edits.mjs` yourself.
- `apply-edits.mjs` only edits markdown, verifies the original text of every change first, and has a `--dry-run`.
  It never rewrites or deletes source code.
- Work files (`.whitebox*`), `whitebox.json` and `whitebox.html` contain verbatim excerpts of your files. Do not
  commit or share them if the source is private.

## Reporting a vulnerability
Please use GitHub's private vulnerability reporting (Security tab -> "Report a vulnerability") instead of a public issue.
