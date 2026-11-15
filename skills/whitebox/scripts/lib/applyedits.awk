# whitebox apply-edits (port of apply-edits.mjs). Environment: WB_ARGFILE (arguments, one per line)
# Every change is verified: the lines on disk must still equal the leaf's original text,
# otherwise that file is left untouched and reported as a conflict.

BEGIN {
  initcommon()
  NA = 0; while ((getline line < ENVIRON["WB_ARGFILE"]) > 0) A_[++NA] = line
  close(ENVIRON["WB_ARGFILE"])
  rootopt = ""; hasroot = 0; dry = 0; drop = 0
  for (i = 1; i <= NA; i++) { if (A_[i] == "--root") { if (!hasroot) { hasroot = 1; rootopt = A_[i + 1] } } if (A_[i] == "--dry-run") dry = 1; if (A_[i] == "--drop-excluded") drop = 1 }
  jf = ""
  for (i = 1; i <= NA; i++) if (substr(A_[i], 1, 2) != "--" && !(hasroot && A_[i] == rootopt)) { jf = A_[i]; break }
  if (jf == "") { print "usage: apply-edits.sh edits.json [--root DIR] [--drop-excluded] [--dry-run]" > "/dev/stderr"; exit 2 }
  if (!jload(jf)) { print "Error: ENOENT: no such file or directory, open '" jf "'" > "/dev/stderr"; exit 1 }
  rt = ("$\001root" in J) ? J["$\001root"] : ""
  root = resolvep(rootopt != "" ? rootopt : (rt != "" ? rt : "."))
  ne = ("$\001edits" in JT) ? JN["$\001edits"] : 0
  nx = ("$\001excluded" in JT) ? JN["$\001excluded"] : 0
  nint = ("$\001intents" in JT) ? JN["$\001intents"] : 0
  codeEx = 0
  for (i = 0; i < nx; i++) if (fld(jp(jp("$", "excluded"), i), "kind") == "code") codeEx++
  nops = 0; nf = 0
  for (i = 0; i < ne; i++) addop(jp(jp("$", "edits"), i), "edit")
  if (drop) for (i = 0; i < nx; i++) if (fld(jp(jp("$", "excluded"), i), "kind") != "code") addop(jp(jp("$", "excluded"), i), "drop")
  changed = 0; conflicts = 0
  for (fi = 1; fi <= nf; fi++) doFile(FILES[fi])
  if (nint || codeEx) print "note: source code is never rewritten or deleted by this tool: " nint " behaviour change note(s) and " codeEx " excluded code piece(s) were ignored (hand the intents to an implementer)."
  print (dry ? "[dry run] " : "") changed " change(s) applied, " conflicts " conflict(s)"
  exit conflicts ? 1 : 0
}

function fld(P, k) { return (jp(P, k) in J) ? J[jp(P, k)] : "" }
function addop(P, kind,   file) {
  nops++
  O_file[nops] = fld(P, "file"); O_start[nops] = fld(P, "start") + 0; O_end[nops] = fld(P, "end") + 0
  O_hasbefore[nops] = (jp(P, "before") in J); O_before[nops] = fld(P, "before")
  O_after[nops] = fld(P, "after"); O_path[nops] = fld(P, "path"); O_kind[nops] = kind
  file = O_file[nops]
  if (!(file in FN)) { FN[file] = 0; FILES[++nf] = file }
  FN[file]++; FO[file, FN[file]] = nops
}
function sliceJoin(a, b,   t, k) {   # L.slice(a-1, b).join("\n"), 1-based inclusive
  t = ""
  if (a < 1) a = 1
  for (k = a; k <= b && k <= NL; k++) t = t (k > a ? "\n" : "") L[k]
  return t
}
function doFile(file,   p, raw, crlf, n, i, j, k, o, list, bad, nn, tmp, x, r, rep, nrep, a, dl, M, out, nlcount, collapse, sep) {
  p = resolvep(substr(file, 1, 1) == "/" ? file : root "/" file)
  raw = slurp(p)
  if (!SL_OK) { print "Error: ENOENT: no such file or directory, open '" p "'" > "/dev/stderr"; exit 1 }
  NL = jsplit(raw, L); crlf = JS_CR
  n = FN[file]
  for (i = 1; i <= n; i++) list[i] = FO[file, i]
  for (i = 2; i <= n; i++) {   # stable, descending by start
    x = list[i]; j = i - 1
    while (j >= 1 && O_start[list[j]] < O_start[x]) { list[j + 1] = list[j]; j-- }
    list[j + 1] = x
  }
  bad = 0
  for (i = 1; i <= n; i++) {
    o = list[i]
    if (!O_hasbefore[o] || sliceJoin(O_start[o], O_end[o]) != O_before[o]) { print "CONFLICT " file ":" jsnum(O_start[o]) "-" jsnum(O_end[o]) " no longer matches the original; skipping file"; bad = 1; conflicts++ }
  }
  for (i = 2; i <= n; i++) if (O_end[list[i]] >= O_start[list[i - 1]]) { print "CONFLICT " file ": overlapping ranges at " jsnum(O_start[list[i - 1]]); bad = 1; conflicts++ }
  if (bad) return
  collapse = 0
  for (i = 1; i <= n; i++) {
    o = list[i]; dl = O_end[o] - O_start[o] + 1; a = O_start[o] - 1
    if (O_kind[o] == "edit") { nrep = split(O_after[o], rep, "\n"); if (nrep == 0) { nrep = 1; rep[1] = "" } }
    else { nrep = 0; collapse = 1 }
    if (a > NL) a = NL
    if (dl > NL - a) dl = NL - a
    splice(a, dl, rep, nrep)
    if (O_kind[o] == "edit") print "edit  " file ":" jsnum(O_start[o]) "-" jsnum(O_end[o])
    else print "drop  " file ":" jsnum(O_start[o]) "-" jsnum(O_end[o]) "  " O_path[o]
    changed++
  }
  if (!dry) {
    sep = crlf ? "\r\n" : "\n"; nlcount = 0
    printf "" > p
    for (k = 1; k <= NL; k++) {
      if (k > 1) { if (collapse && nlcount >= 2) { } else { printf "%s", sep > p; nlcount++ } }
      printf "%s", L[k] > p
      if (L[k] != "") nlcount = 0
    }
    close(p)
  }
}
# L.splice(a, dl, ...rep) on L[1..NL] (a is 0-based)
function splice(a, dl, rep, nrep,   k, d, tail, nt) {
  d = nrep - dl
  if (d < 0) { for (k = a + dl + 1; k <= NL; k++) L[k + d] = L[k]; for (k = NL + d + 1; k <= NL; k++) delete L[k] }
  else if (d > 0) { for (k = NL; k >= a + dl + 1; k--) L[k + d] = L[k] }
  for (k = 1; k <= nrep; k++) L[a + k] = rep[k]
  NL += d
}
