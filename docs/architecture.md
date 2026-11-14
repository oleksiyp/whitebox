# Architecture

whitebox turns a directory of markdown and source code into one tree that a person can survey, prune and edit.
The central design decision is a **strict split of responsibility**:

> Scripts own everything that must be exact. Models own everything that is fuzzy. A script checks every model output.

| Exact (scripts, `scripts/whitebox.mjs`) | Fuzzy (Haiku agents, `workflow.js`) |
|---|---|
| which files are analysed | title of a piece (2-4 words) |
| cutting files into pieces with line ranges | where a piece sits in the tree (path of 2-4 word segments) |
| verbatim text of every piece | one-sentence description of a branch |
| validating agent output | for code: the plain-language specification of a piece |
| merging, ids, building JSON, embedding the editor | grouping of over-wide branches |
| verified write-back | |

Consequences: a model can never corrupt the source (it never sees a line number and never writes source text), a
sloppy model answer is rejected by a checker and repaired in the same agent session, and the expensive part can be
done by a cheap model.

## Pipeline

```
 split ──► outline ──► verify ──► merge ──► describe ──► reshape ──► build ──► editor ──► write-back
 (code)   (agents)    (code)    (agent)   (agents)     (agents)    (code)    (HTML)     (code)
```

1. **split** - select files (see `skills/whitebox/references/selection.md`), cut them into *pieces*, form about
   sqrt(N files) *groups* of neighbouring files balanced by size (files of one family such as `x.md`, `x-2.md` stay
   together), and cut each group into *windows* of about 220 pieces. Prints a cost estimate.
2. **outline** - one agent chain per group, windows in order. An agent runs `whitebox.mjs window G N`, which prints
   the instructions, the branches created so far in this group (for naming consistency) and the numbered pieces with
   short snippets. It writes one line per piece, `id;Theme/Sub Theme/Piece Title` (code: `;description`), plus a
   running summary, and runs `whitebox.mjs check G N` until it prints `OK`. The checker enforces: every id exactly once,
   segments of 2-4 words, unique paths, no path that is a prefix of another, a description for every code piece.
3. **verify** - `check-all` finds windows that still fail; they are redone.
4. **merge** - one agent sees only the top two levels of each group's outline plus its summary (a few hundred lines,
   never the thousands of piece lines) and returns prefix rewrites `group;Old Top;New/Prefix`. A script applies them,
   so the model never reprints the tree. The result must have 3-8 top-level branches.
5. **describe** - one agent per group writes a one-sentence description for each branch of depth <= 3.
6. **reshape** - branches with more than 9 children are regrouped into themed sub-branches by one agent each
   (repeated up to 3 rounds); a script applies the groupings and carries the descriptions to the new paths.
7. **build** - `tree.paths` becomes `whitebox.json` (nested, with the verbatim `text` of each piece read back from the
   files) and `whitebox.paths` (flat, `find`-style). `validate.mjs` re-checks that every leaf's text equals the file lines,
   that no non-blank line is uncovered or covered twice, and the shape of the tree.
8. **editor** - `build-editor.mjs` embeds the JSON into `editor.template.html`, a dependency-free page.

## Pieces and identity
A piece is `file:start-end` (1-based, inclusive) plus its verbatim text. Pieces never overlap and together cover every
non-blank, non-heading line (for source files: every non-blank line). Headings of markdown become branch titles and are
not pieces. A tree node is identified by its path; a leaf's identity is its range. That is what makes write-back safe:
an edit says "lines 40-44 used to be exactly this text, replace them with that".

Markdown is cut by structure (list items with their nested bullets, tables, fenced blocks, paragraphs; small neighbours are
merged up to ~80 words). Source is cut at top-level declarations: a language-agnostic scanner tracks bracket depth and
column-0 starts, attaches leading comments and decorators to the next declaration, merges small units and splits long
ones at blank lines (~200 words). It is deliberately heuristic, not a parser: it works for Go, TypeScript, Python, Rust, Java and
similar without per-language code, and a wrong cut only changes how a function is split between two pieces; it cannot lose or alter text.

## Code as specification (inversion)
For code pieces the outline agent writes a description in requirement style (behaviour, inputs/outputs, rules,
invariants) and places the piece under a *capability* path, not under file or function names. The editor shows the
description as the card body and keeps the code behind a toggle; context exports use the description. Editing a
description is recorded as an `intent` (a behaviour-change note). Source code is never rewritten.

## Write-back
`apply-edits.mjs` groups changes by file, sorts them from the bottom up (so earlier line numbers stay valid), compares the
current lines with the recorded original text, and only then replaces or deletes. A mismatch skips that whole file and reports a
conflict. CRLF files keep their line endings. `--dry-run` shows what would happen. Code pieces (edited or excluded) are
reported and ignored.

## Editor
One HTML file. The tree is embedded as JSON. Outline rows are built lazily, large sections load on demand, statistics are computed
in one pass, and filtering is debounced and capped, so a 15,000-piece tree stays responsive. Markdown cards render with a
small built-in renderer (tables, lists, code, emphasis, links); a click switches to the raw text. State (edits, exclusions,
collapsed branches, outline width) persists in `localStorage` per tree.

## Cost model
Calibrated on two real runs: about 0.7k Haiku tokens per prose piece and 1.5k per code piece, plus ~25% for merge and reshape.
`whitebox.mjs split` prints the estimate; real runs landed between 0.5x and 2.5x of it.

## Known limits and ideas
- Not incremental: after write-back or source changes, line ranges are stale and the project is re-split. Idea: reuse paths of
  pieces whose text hash is unchanged.
- Titles and descriptions are model-written and only spot-checked by default.
- Code is analysed per declaration; cross-file flows are only as good as the grouping.
- Behaviour-change notes on code are not applied; they are a work list for a person or a coding agent.
