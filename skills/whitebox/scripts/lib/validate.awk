# whitebox validate (port of validate.mjs). Environment: WB_FILE
# JS here uses native trim and \s (Unicode whitespace), unlike whitebox.mjs, so normalise those sequences first.

BEGIN {
  initcommon()
  F = ENVIRON["WB_FILE"]; if (F == "") F = "whitebox.json"
  if (!jload(F)) { print "Error: ENOENT: no such file or directory, open '" F "'" > "/dev/stderr"; exit 1 }
  root = ("$\001root" in J) ? J["$\001root"] : ""
  if (root == "") root = "."
  BASE = (substr(root, 1, 1) == "/") ? normpath(root) : resolvep(dirnamep(F) "/" root)
  NERRS = 0; NWARN = 0; NIDS = 0; NLV = 0; DEPTH = 0
  walk(jp("$", "tree"), 0, "")
  coverage()
  printf "%d leaves, %d branches, depth %d, files: ", NLV, NIDS - NLV, DEPTH
  for (i = 1; i <= NBY; i++) printf "%s%s", (i > 1 ? ", " : ""), BYF[i]
  printf "\n"
  for (i = 1; i <= NWARN; i++) print "warn: " WARN[i]
  for (i = 1; i <= NERRS; i++) print "ERROR: " ERRS[i]
  exit NERRS ? 1 : 0
}

function adderr(m) { ERRS[++NERRS] = m }
function addwarn(m) { WARN[++NWARN] = m }
function uws(s) { return s }
function words(s) { s = uws(s); if (trim(s) == "") return 1; return W(s) }
function jv(P, k) { return (jp(P, k) in J) ? J[jp(P, k)] : "undefined" }
function has(P, k) { return (jp(P, k) in JT) }
function truthy(P, k) { return has(P, k) && J[jp(P, k)] != "" && J[jp(P, k)] != "false" && J[jp(P, k)] != "null" && JT[jp(P, k)] != "z" }
function loadlines(file,   raw, n, i, ab) {
  if (file in LNN) return LNN[file]
  ab = (substr(file, 1, 1) == "/") ? normpath(file) : normpath(BASE "/" file)
  raw = slurp(ab)
  if (!SL_OK) return -1
  n = jsplit(raw, TA)
  LNN[file] = n
  for (i = 1; i <= n; i++) LL[file, i] = TA[i]
  return n
}
function walk(P, d, path,   p, title, nk, i, c, k, t, seen, dup, lastLine, lf, id, n, real, text, kind, s, e, wd, ls, le) {
  if (d > DEPTH) DEPTH = d
  title = jv(P, "title"); p = path "/" title
  id = jv(P, "id")
  if (!truthy(P, "id") || (id in IDS)) adderr(p ": missing/duplicate id " id)
  if (!(id in IDS)) { IDS[id] = 1; NIDS++ }
  if (d > 0 && !(has(P, "title") && JT[jp(P, "title")] == "s" && words(title) >= 2 && words(title) <= 4)) adderr(p ": title must be 2-4 words")
  if (has(P, "children")) {
    c = jp(P, "children"); nk = JN[c]
    if (nk == 0) adderr(p ": empty branch")
    if (d == 0 && (nk < 3 || nk > 8)) addwarn("root has " nk " top-level branches (want 3-8)")
    if (d > 8) addwarn(p ": depth " d " (>8)")
    if (nk < 2 && d > 0) addwarn(p ": single-child branch")
    if (nk > 9) addwarn(p ": " nk " children (>9)")
    dup = 0; delete seen
    for (i = 0; i < nk; i++) { t = jv(jp(c, i), "title"); if (t in seen) dup = 1; seen[t] = 1 }
    if (dup) adderr(p ": duplicate sibling titles")
    delete lastLine
    for (i = 0; i < nk; i++) {
      k = jp(c, i)
      if (!has(k, "children")) {
        lf = jv(k, "file")
        if (truthy(k, "file") && has(k, "start") && jsnumber(J[jp(k, "start")]) && NUMV <= ((lf in lastLine) ? lastLine[lf] : 0)) addwarn(p ": \"" jv(k, "title") "\" out of source order")
        lastLine[lf] = (has(k, "start") && jsnumber(J[jp(k, "start")])) ? NUMV : 0
      }
    }
    for (i = 0; i < nk; i++) walk(jp(c, i), d + 1, p)
  } else {
    NLV++; LV[NLV] = P
    if (!truthy(P, "file") || !intnum(P, "start") || !intnum(P, "end") || (J[jp(P, "end")] + 0) < (J[jp(P, "start")] + 0)) { adderr(p ": bad file/start/end"); return }
    lf = J[jp(P, "file")]; s = J[jp(P, "start")] + 0; e = J[jp(P, "end")] + 0
    n = loadlines(lf)
    if (n < 0) { adderr(p ": cannot read " lf); return }
    real = ""
    for (i = s; i <= e && i <= n; i++) real = real (i > s ? "\n" : "") LL[lf, i]
    text = has(P, "text") ? J[jp(P, "text")] : ""
    kind = has(P, "kind") ? J[jp(P, "kind")] : ""
    if (real != text || !has(P, "text")) adderr(p ": text differs from " lf ":" J[jp(P, "start")] "-" J[jp(P, "end")])
    if (kind == "code" && !truthy(P, "description")) addwarn(p ": code piece without description")
    wd = words(text)
    if (kind != "code" && wd > 250 && e > s) adderr(p ": leaf has " wd " words (max 250; spans " (e - s + 1) " lines, split it)")
    else if (kind != "code" && wd > 120) addwarn(p ": leaf has " wd " words (>120)")
    if (s > n) crash()
    ls = LL[lf, s]
    if (trim(uws(ls)) == "") adderr(p ": leaf starts or ends on a blank line")
    else { if (e > n) crash(); le = LL[lf, e]; if (trim(uws(le)) == "") adderr(p ": leaf starts or ends on a blank line") }
  }
}
function crash() { print "TypeError: Cannot read properties of undefined (reading 'trim')" > "/dev/stderr"; exit 1 }
function intnum(P, k) { return has(P, k) && JT[jp(P, k)] == "n" && jsnumber(J[jp(P, k)]) && isint(NUMV) }

function coverage(   i, f, k, n, nf, ls, j, tmp, x, y, cov, isCode, fence, miss, nm, ml, t, tu, l, cnt, idx) {
  NBY = 0
  for (i = 1; i <= NLV; i++) {
    f = jv(LV[i], "file")
    if (!(f in BYN)) { BYN[f] = 0; BYF[++NBY] = f }
    BYN[f]++; BYI[f, BYN[f]] = LV[i]
  }
  for (k = 1; k <= NBY; k++) {
    f = BYF[k]; n = BYN[f]
    for (i = 1; i <= n; i++) { ST[i] = J[jp(BYI[f, i], "start")] + 0; EN[i] = J[jp(BYI[f, i], "end")] + 0; ID[i] = i }
    for (i = 2; i <= n; i++) {   # stable insertion sort by start
      x = ID[i]; j = i - 1
      while (j >= 1 && ST[ID[j]] > ST[x]) { ID[j + 1] = ID[j]; j-- }
      ID[j + 1] = x
    }
    for (i = 2; i <= n; i++) if (ST[ID[i]] <= EN[ID[i - 1]]) adderr(f ": leaves overlap at line " ST[ID[i]] " (\"" jv(BYI[f, ID[i]], "title") "\")")
    delete cov; isCode = 0
    for (i = 1; i <= n; i++) {
      if (jv(BYI[f, i], "kind") == "code") isCode = 1
      for (j = ST[i]; j <= EN[i]; j++) cov[j] = 1
    }
    nf = loadlines(f)
    if (nf < 0) { print "Error: ENOENT: no such file or directory, open '" BASE "/" f "'" > "/dev/stderr"; exit 1 }
    fence = 0; nm = 0; ml = ""
    for (j = 1; j <= nf; j++) {
      t = LL[f, j]
      if (substr(t, 1, 3) == "```") fence = !fence
      tu = uws(t)
      if (trim(tu) != "" && (isCode || fence || tu !~ /^#(#?#?#?#?#?)[ \t\r\n\f\013]/) && !(j in cov)) { nm++; if (nm <= 8) ml = ml (nm > 1 ? "," : "") j }
    }
    if (nm) adderr(f ": " nm " content lines not covered, e.g. " ml)
  }
}
