---
name: whitebox
description: Turn a codebase or a pile of markdown specs into a whitebox - one overseeable tree of small titled pieces with plain-language descriptions - and review it in an interactive page (published as an Artifact) where branches and pieces can be included, excluded and edited. For source code, each piece is inverted into a specification statement (what it does, not how), so a reader sees the system instead of the code. Use this whenever the user wants to understand, survey, map or summarise a project or a large spec, asks "what is in this repo / these specs", wants to prune or restructure a spec, wants a compact context pack of a codebase, or wants to turn code back into requirements - even if they never say "whitebox".
---

# whitebox

Makes a project's insides visible. Output: a tree of 2-4 word titles, branches with a one-line description,
leaves that keep exact `file:start-end` line ranges, plus an interactive editor page. The result is published as a
private **Artifact**; no file is ever created in the user's project.

- **Markdown pieces** show as rendered markdown and can be edited; edits can be written back to the files.
- **Code pieces** show a plain-language *description* (an inversion of the code into a requirement); the code
  is behind "Show code". Editing a description records a *behaviour change note*. This skill never rewrites or
  deletes source code.

**Division of labour.** Scripts do everything that must be exact (file selection, segmenting, line ranges,
verbatim text, validation, embedding, write-back). Cheap Haiku agents (Workflow tool) only invent titles,
groupings, summaries and the code-to-spec descriptions, and each agent output is checked by a script the agent
runs until it prints `OK`. Agents never copy source text or line numbers, so the tree cannot corrupt the source.

## Where files go (hard rule)

**Never create a file in the user's project or in the current directory.** Not a work directory, not `whitebox.json`, not the page.
Everything temporary lives in the **scratchpad** directory named in the system prompt; the result is an **Artifact**.

- `S` = this skill's base directory (shown when the skill loads).
- `W` = `<scratchpad>/whitebox-<project>`. If the system prompt names no scratchpad, make one outside the project with
  `mktemp -d "${TMPDIR:-/tmp}/whitebox-XXXXXX"` (or the platform's temp directory) and say so. The tools refuse to run without `--work`,
  so a forgotten flag cannot drop files into a project.
- Always use **absolute paths** (the commands print absolute paths for agents, so a different working directory never matters).
- The only files this skill may ever change in the project are the markdown files the user explicitly asks to have edited (step 8).
- git is optional (without it files are found by walking the directory).

## Runtime: nothing to install

The four tools exist in three identical implementations, so the skill runs on a machine with only its base system. Pick the first that works:

1. **Node >= 18** (`node --version`): `node S/scripts/<tool>.mjs`. Fastest.
2. **POSIX `sh` + `awk`** (macOS, Linux, Git Bash, WSL; always present): `sh S/scripts/<tool>.sh`.
3. **PowerShell** (Windows): `pwsh -NoProfile -File S/scripts/<tool>.ps1`, or on Windows PowerShell 5.1
   `powershell -NoProfile -ExecutionPolicy Bypass -File S/scripts/<tool>.ps1`.

`<tool>` is `whitebox`, `apply-edits`, `validate` or `build-editor`; the arguments, messages and files are the same in all three. Below,
`CLI`, `APPLY`, `VALIDATE` and `EDITOR` mean "the launcher you picked plus that tool's script". Use the same implementation for a whole
run. Say which one you picked only when it is not Node. The commands printed for agents already contain the right launcher.

## Workflow

Ask the user at the points marked **ASK**. Prefer the AskUserQuestion tool; otherwise ask in chat. Why: the run costs
real tokens and sends file contents to Haiku subagents (the same data flow as Claude reading them), and write-back
changes files, so those are the user's decisions.

1. **Split** - `CLI split <dir-or-files...> --work W`. Prints which files were selected and, grouped by reason,
   what was skipped (.gitignore, hidden, vendored, generated, tests, config, secrets, binaries...) plus a cost
   estimate. Details and flags (`--tests --config --include --exclude --max-kb`): `references/selection.md`.
2. **ASK - scope and go/no-go.** Show the selection summary and the estimate (agents, tokens, minutes) in plain words.
   Ask: proceed / change the selection (tests? config? other exclusions?) / cancel. Mention that the content of
   included files is processed by Haiku subagents; if the repo is proprietary or sensitive, say so and let them decide.
   Re-run split with other flags if they want changes. Do not start the workflow without a yes.
3. **Workflow** - `CLI groups-args --work W` prints the args (absolute paths and the full launcher command in `run`). The Workflow tool loads scripts from the
   working directory or the scratchpad, and the skill may live elsewhere (plugin or global install), so first
   `cp S/workflow.js W/workflow.js`, then call the Workflow tool with `scriptPath: W/workflow.js` (absolute) and those args as a
   JSON value. Phases: Outline -> Verify -> Merge -> Describe -> Reshape. It is resumable. If the Workflow tool is unavailable,
   see `references/troubleshooting.md` (manual fallback).
4. **Verify yourself, never trust the summary** - read-only commands only: `CLI status --work W`,
   `CLI check-all --work W` (no failing windows), `CLI reshape-count --work W` (count 0).
   Never re-run `apply-merge` or `reshape-list` to check: they rebuild or reset state.
5. **Build** - `CLI build --work W` (writes `W/whitebox.json` and `W/whitebox.paths`), then `VALIDATE W/whitebox.json`
   (0 errors; warnings are informational), then the page:
   `EDITOR W/whitebox.json W/<project>.html --artifact --title "<Project> Whitebox"` (`--artifact` writes the fragment the Artifact tool wraps; the
   title is a 2-4 word name, e.g. "Billing Whitebox"). Check the size: an Artifact page must be **16 MB or smaller**
   (a 14,000-piece tree is about 9 MB). If it is bigger, **ASK** the user to narrow the selection (`--exclude`) and re-run from step 1.
6. **Publish as an Artifact.** Load the `artifact-design` and `artifact-capabilities` skills first (the Artifact tool requires them), then call the
   Artifact tool: `file_path: W/<project>.html`, `capabilities: {"downloads": true, "db": {}}`, `icon: "tree"`, and a one-sentence `description`
   (for example "Plain-language map of the billing service: 8 areas, 480 pieces."). The page uses `downloads` to save exports (a sandboxed page cannot
   start downloads itself) and `db` to send edits back to this session. The Artifact is private by default; it contains verbatim excerpts of the
   user's files, so never share or publish it further without asking. If the Artifact tool is unavailable, say so and give the user the path of
   the page in the scratchpad (standalone, still not in the project). Tell the user: filter with `/`, click a card to edit, In/Out pills include or
   exclude, the Changes drawer sends or exports. Be honest about quality: titles and descriptions are model-written and only spot-checked.
7. **Looking at the result with the user** - offer to read branches aloud, answer questions from the tree, or export "Context .md" (descriptions
   for code, text for docs) as a compact context pack (the page saves it through the viewer's download prompt).
8. **Write back (markdown only).** The user presses **Send edits to Claude** in the page. Read them with the `ArtifactData` tool: `list` the collection
   `whitebox-edits`, take the `meta` document (`n` parts) and the documents `c0000`... in order of `i`, concatenate their `part` strings into
   `W/whitebox-edits.json` (scratchpad). If the page could not send (viewer signed out), the user used *Download edits*: ask where the file is.
   Then `APPLY <edits.json> --dry-run`, show it, **ASK** before applying for real. `--drop-excluded` deletes excluded *markdown* pieces: ASK
   separately, it is destructive. Each change is verified against the original lines; on a mismatch the file is skipped and reported.
   Behaviour-change notes on code are never applied: hand them to the user as a work list (offer to implement them as a normal coding
   task). Afterwards delete the `whitebox-edits` documents with `ArtifactData`.
9. After write-back the line ranges are stale; re-run from step 1 before editing again (a new Artifact version of the same page is fine).

## When something goes wrong

- A window keeps failing its check: read the checker message, fix the agent's output file by hand or re-run just that
  window; never edit the source.
- Merge or reshape looks poor: **ASK** whether to redo that phase with a stronger model. See `references/troubleshooting.md`.
- Formats of every file, if you need to read or repair them: `references/formats.md`.

## Principles

- Titles and groups for code describe capabilities ("Retry Failed Deployments"), not files, packages or functions.
- Be upfront about cost and about what the selection rules skipped; a silent omission reads as full coverage.
- Keep the user's repo clean: scratch output lives in `W` in the scratchpad, the result is an Artifact, and nothing else is written.
