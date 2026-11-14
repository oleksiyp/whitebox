---
name: whitebox
description: Turn a codebase or a pile of markdown specs into a whitebox - one overseeable tree of small titled pieces with plain-language descriptions - and review it in an interactive HTML editor where branches and pieces can be included, excluded and edited. For source code, each piece is inverted into a specification statement (what it does, not how), so a reader sees the system instead of the code. Use this whenever the user wants to understand, survey, map or summarise a project or a large spec, asks "what is in this repo / these specs", wants to prune or restructure a spec, wants a compact context pack of a codebase, or wants to turn code back into requirements - even if they never say "whitebox".
---

# whitebox

Makes a project's insides visible. Output: a tree of 2-4 word titles, branches with a one-line description,
leaves that keep exact `file:start-end` line ranges, plus a self-contained HTML editor.

- **Markdown pieces** show as rendered markdown and can be edited; edits can be written back to the files.
- **Code pieces** show a plain-language *description* (an inversion of the code into a requirement); the code
  is behind "Show code". Editing a description records a *behaviour change note*. This skill never rewrites or
  deletes source code.

**Division of labour.** Scripts do everything that must be exact (file selection, segmenting, line ranges,
verbatim text, validation, embedding, write-back). Cheap Haiku agents (Workflow tool) only invent titles,
groupings, summaries and the code-to-spec descriptions, and each agent output is checked by a script the agent
runs until it prints `OK`. Agents never copy source text or line numbers, so the tree cannot corrupt the source.

`S` = this skill's base directory (shown when the skill loads). `CLI` = `S/scripts/whitebox.mjs`.
`W` = work directory. Use `<scratchpad>/whitebox-<project>` when the system prompt names a scratchpad directory (scratch files
never touch the user's directories and need no permission prompts); otherwise `.whitebox-<project>` in the current directory,
which must not be inside the analysed repo. Always use **absolute paths**: the commands print absolute paths for agents, so a
different working directory can never break a run.
The deliverables (`whitebox-<project>.json`, `.html`, `.paths`) go to the current directory unless the user says otherwise,
because the scratchpad is temporary; tell the user where they are. Node >= 18; git is optional.

## Workflow

Ask the user at the points marked **ASK**. Prefer the AskUserQuestion tool; otherwise ask in chat. Why: the run costs
real tokens and sends file contents to Haiku subagents (the same data flow as Claude reading them), and write-back
changes files, so those are the user's decisions.

1. **Split** - `node CLI split <dir-or-files...> --work W`. Prints which files were selected and, grouped by reason,
   what was skipped (.gitignore, hidden, vendored, generated, tests, config, secrets, binaries...) plus a cost
   estimate. Details and flags (`--tests --config --include --exclude --max-kb`): `references/selection.md`.
2. **ASK - scope and go/no-go.** Show the selection summary and the estimate (agents, tokens, minutes) in plain words.
   Ask: proceed / change the selection (tests? config? other exclusions?) / cancel. Mention that the content of
   included files is processed by Haiku subagents; if the repo is proprietary or sensitive, say so and let them decide.
   Re-run split with other flags if they want changes. Do not start the workflow without a yes.
3. **Workflow** - `node CLI groups-args --work W` prints the args (absolute paths). The Workflow tool loads scripts from the
   working directory or the scratchpad, and the skill may live elsewhere (plugin or global install), so first
   `cp S/workflow.js W/workflow.js`, then call the Workflow tool with `scriptPath: W/workflow.js` (absolute) and those args as a
   JSON value. Phases: Outline -> Verify -> Merge -> Describe -> Reshape. It is resumable. If the Workflow tool is unavailable,
   see `references/troubleshooting.md` (manual fallback).
4. **Verify yourself, never trust the summary** - read-only commands only: `node CLI status --work W`,
   `node CLI check-all --work W` (no failing windows), `node CLI reshape-count --work W` (count 0).
   Never re-run `apply-merge` or `reshape-list` to check: they rebuild or reset state.
5. **Build** - `node CLI build --work W --out <cwd>/whitebox-<project>.json`, then `node S/scripts/validate.mjs <that json>`
   (0 errors; warnings are informational), then `node S/scripts/build-editor.mjs <that json> <cwd>/whitebox-<project>.html`.
   Open the HTML. Tell the user: filter with `/`, click a card to edit, In/Out pills include or exclude, the Changes
   drawer exports. Be honest about quality: titles and descriptions are model-written and only spot-checked.
6. **Looking at the result with the user** - offer to read branches aloud, answer questions from the tree, or
   export "Context .md" (descriptions for code, text for docs) as a compact context pack.
7. **Write back (markdown only)** - the user clicks *Download edits* (`whitebox-edits.json`). Run
   `node S/scripts/apply-edits.mjs whitebox-edits.json --dry-run`, show it, **ASK** before applying for real.
   `--drop-excluded` deletes excluded *markdown* pieces: ASK separately, it is destructive. Each change is verified
   against the original lines; on a mismatch the file is skipped and reported. Behaviour-change notes on code
   are never applied: hand them to the user as a work list (offer to implement them as a normal coding task).
8. After write-back the line ranges are stale; re-run from step 1 before editing again.

## When something goes wrong

- A window keeps failing its check: read the checker message, fix the agent's output file by hand or re-run just that
  window; never edit the source.
- Merge or reshape looks poor: **ASK** whether to redo that phase with a stronger model. See `references/troubleshooting.md`.
- Formats of every file, if you need to read or repair them: `references/formats.md`.

## Principles

- Titles and groups for code describe capabilities ("Retry Failed Deployments"), not files, packages or functions.
- Be upfront about cost and about what the selection rules skipped; a silent omission reads as full coverage.
- Keep the user's repo clean: all scratch output lives in `W` and the generated files next to it.
