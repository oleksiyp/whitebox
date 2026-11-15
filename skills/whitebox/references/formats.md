# Formats

All files below live in the work directory `W` unless stated otherwise. They are plain text so they can be inspected
and repaired by hand.

| File | Written by | Content |
|---|---|---|
| `pieces.json` | split | `{root, files[{rel,bytes,first,last,lang}], pieces[{i,f,s,e,w,hp,sn,k?,lang?}]}` |
| `groups.json` | split | groups of files and the windows (id ranges) each agent handles |
| `selection.json`, `estimate.json` | split | what was included/skipped and why; the cost estimate |
| `out/gG-wN.txt` | outline agent | one line per piece: `id;Theme/Sub Theme/Piece Title` and, for code, `id;path;description` |
| `out/gG-wN.sum` | outline agent | running summary of what the group covers (<= 60 words) |
| `merge.txt` | merge agent | `group;Old Top Segment;New/Prefix` |
| `tree.paths` | apply-merge, apply-reshape | `group;full/path;file:start-end` |
| `leafdesc.json` | apply-merge | `{ "file:start-end": "description" }` for code pieces |
| `desc/gG.txt`, `desc/_all.txt` | describe agent, apply-reshape | `Branch/Path;one-sentence description` |
| `reshape/rN.txt` | reshape agent | `Child Title;Group Title;description` |
| `reshape.applied` | apply-reshape | marker: apply-merge refuses to overwrite after this (use `--force`) |

**`whitebox.json`** (output of `build`): `{version, root, title, tree}`. Branch: `{id, title, description?, children}`.
Leaf: `{id, title, file, start, end, text}`; code leaves add `{kind:"code", lang, description}`. The order of keys inside an object
is not significant to readers (the implementations write them in the same order, `title` first and `id` near the end, which keeps files byte-identical).
**`whitebox.paths`**: `group;path;file:start-end;description`, one line per node, `find`-style.

**`whitebox-edits.json`** (downloaded from the editor):
`{version, root, edits:[{file,start,end,before,after,path}], excluded:[{file,start,end,before,path,kind?}],
intents:[{file,start,end,path,before,after}]}`. `intents` are description changes on code pieces; `excluded` entries with
`kind:"code"` are never deleted.
