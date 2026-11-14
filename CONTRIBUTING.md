# Contributing

Thanks for helping. whitebox is small on purpose: zero dependencies, one CLI, one HTML template.

## Setup
```sh
git clone https://github.com/oleksiyp/whitebox && cd whitebox
npm test        # Node >= 20 for the tests (the tool itself runs on Node >= 18); needs git
```

## Layout
- `skills/whitebox/` - the skill itself (this is what users install): `SKILL.md`, `workflow.js`, `reshape.js`,
  `scripts/` (CLI, validator, editor builder, write-back), `references/`.
- `test/` - `node:test` suites. Fixtures are generated into temp directories, so nothing private can leak in.
- `docs/` - architecture notes.

## Ground rules
1. **Exactness lives in code, fuzziness in the model.** Anything that must be exact (line ranges, verbatim text,
   validation, write-back) belongs in a script with a test. Agents only produce titles, paths and descriptions,
   and every agent output must have a checker the agent runs until it prints `OK`.
2. **Source code is never modified by write-back.** Keep that invariant and its test.
3. **Zero runtime dependencies.** The editor is one self-contained HTML file that works from `file://`.
4. **Tests that can fail.** For segmenter or selection changes, add a case that fails without your change.
   Quick mutation check: break the code on purpose and make sure a test notices.
5. **No private data** in fixtures, docs or screenshots.

## Changing the agent prompts
The prompts are printed by `whitebox.mjs window|merge-input|describe-input|reshape-input`. If you change one, run it on a real
project (a few windows are enough) and compare the checker pass rate and the output quality before and after;
describe what you saw in the PR.

## Pull requests
Keep them focused, update `CHANGELOG.md`, and fill in the template.
