# Troubleshooting

**The Workflow tool is not available.** The workflow only fans the same commands out to agents. Do it by hand with the
Agent tool: for each group, for each window in order, spawn one Haiku agent with
"Run `node CLI window G N --work W` with Bash, read the whole output and carry out the TASK it describes; reply done
when the check prints OK". Then one agent for `merge-input`, one per group for `describe-input G`, and one per wide branch
for `reshape-input N` (after `reshape-list`), followed by `apply-reshape`. Windows of one group must run in order.

**A window fails its check repeatedly.** `node CLI check G N --work W` prints what is wrong (missing ids, titles that are
not 2-4 words, duplicate paths, missing code descriptions). Edit `W/out/gG-wN.txt` yourself or delete it and re-run the window.

**Redo only the reshape phase** (e.g. quality was poor): `rm W/reshape.applied W/desc/_all.txt`,
`node CLI apply-merge --work W --force`, then the Workflow tool with `S/reshape.js` and args `{"work":"W","cli":"CLI"}`.

**Redo only the merge:** delete `W/merge.txt`, run the merge agent again (`merge-input`), then `apply-merge --force`
and redo reshape as above.

**The editor is slow.** Trees with 15k pieces load lazily and stay responsive; a filter that matches more than 400 pieces
asks you to narrow it. Use a smaller selection (`--exclude`) if a branch is too big to review.

**The source changed after the split.** Line ranges become stale. `apply-edits` detects this (it compares the original
text) and skips the file; re-run split.

**Cost is higher than the estimate.** The estimate is calibrated on two real runs and can be off by 0.5x to 2.5x. Prose is
cheaper than code. Reduce the selection or skip tests/config.
