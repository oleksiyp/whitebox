# whitebox: every subcommand except split (port of whitebox.mjs). Environment: WB_CMD WB_WORKARG WB_SELF WB_POSFILE WB_TPL WB_TMP
#   WB_FORCE WB_ALLOWSTALE WB_OUTARG WB_SHA plus WB_CWD.

BEGIN {
  initcommon()
  CMD = ENVIRON["WB_CMD"]; WORK = resolvep(ENVIRON["WB_WORKARG"]); WORKQ = q(WORK)
  SELFABS = resolvep(ENVIRON["WB_SELF"]); SELF = q(SELFABS); RUN = "sh " SELF
  TPL = ENVIRON["WB_TPL"]; TMPD = ENVIRON["WB_TMP"]; SHA = ENVIRON["WB_SHA"]
  NPOS = 0; while ((getline line < ENVIRON["WB_POSFILE"]) > 0) POS[++NPOS] = line
  close(ENVIRON["WB_POSFILE"])
  if (CMD == "window") cmdWindow()
  else if (CMD == "check") cmdCheck()
  else if (CMD == "check-all") cmdCheckAll()
  else if (CMD == "status") cmdStatus()
  else if (CMD == "merge-input") cmdMergeInput()
  else if (CMD == "apply-merge") cmdApplyMerge()
  else if (CMD == "describe-input") cmdDescribeInput()
  else if (CMD == "check-desc") cmdCheckDesc()
  else if (CMD == "reshape-list") cmdReshapeList()
  else if (CMD == "reshape-count") cmdReshapeCount()
  else if (CMD == "reshape-input") cmdReshapeInput()
  else if (CMD == "check-reshape") cmdCheckReshape()
  else if (CMD == "apply-reshape") cmdApplyReshape()
  else if (CMD == "groups-args") cmdGroupsArgs()
  else if (CMD == "estimate") cmdEstimate()
  else if (CMD == "build") cmdBuild()
  exit 0
}

function die(m) { print m > "/dev/stderr"; exit 1 }
function wp(a) { return WORK "/" a }
function tpl(name,   f, line, t) {
  f = TPL "/" name; t = ""
  while ((getline line < f) > 0) t = t line "\n"
  close(f)
  return t
}
# replace every @NAME@ in s by val (plain text, no regex semantics)
function subst(s, name, val,   tag, i, o) {
  tag = "@" name "@"; o = ""
  while ((i = index(s, tag)) > 0) { o = o substr(s, 1, i - 1) val; s = substr(s, i + length(tag)) }
  return o s
}
function readJ(f) {
  if (!jload(f)) die("Error: ENOENT: no such file or directory, open '" f "'")
}
function sortkeys(arr, n,   f, cmd, k, line, i) {
  f = TMPD "/ks"
  printf "" > f
  for (i = 1; i <= n; i++) print arr[i] > f
  close(f)
  cmd = "sort < " shq(f); k = 0
  while ((cmd | getline line) > 0) SORTED[++k] = line
  close(cmd)
  return k
}
function same(a, b) { return (a "") == (b "") }

# ---------------- shared readers ----------------
# pieces.json: records are one per line (formats.md); anything else falls back to the generic reader
function jrec(line,   len, pos, c, key, chunk) {
  delete R; len = length(line); pos = index(line, "{") + 1
  while (pos <= len) {
    if (substr(line, pos, 1) != "\"") break
    pos = jstring(line, pos, len); key = JSV; pos++
    c = substr(line, pos, 1)
    if (c == "\"") { pos = jstring(line, pos, len); R[key] = junesc(JSV) }
    else { chunk = substr(line, pos, 40); match(chunk, /^[^,}]*/); R[key] = substr(chunk, 1, RLENGTH); pos += RLENGTH }
    c = substr(line, pos, 1)
    if (c == ",") pos++; else break
  }
}
function loadPieces(   f, line, st, ok, i, p, np) {
  if (PLOADED) return
  PLOADED = 1; f = wp("pieces.json"); NFILES = 0; NPIECES = 0
  if ((getline line < f) < 0) die("Error: ENOENT: no such file or directory, open '" f "'")
  if (substr(line, 1, 9) == "{\"root\":\"") {
    jstring(line, 9, length(line)); PROOT = junesc(JSV); st = 1; ok = 1
    while ((getline line < f) > 0) {
      if (st == 1) {
        if (substr(line, 1, 3) == "],\"") { st = 2; continue }
        if (substr(line, 1, 7) != "{\"rel\":") { ok = 0; break }
        jrec(line); FL_rel[NFILES] = R["rel"]; FL_h[NFILES] = R["h"]; NFILES++
      } else {
        if (substr(line, 1, 2) == "]}") break
        if (substr(line, 1, 5) != "{\"i\":") { ok = 0; break }
        jrec(line); i = R["i"] + 0; if (i > NPIECES) NPIECES = i
        P_f[i] = R["f"] + 0; P_s[i] = R["s"] + 0; P_e[i] = R["e"] + 0; P_hp[i] = R["hp"]; P_sn[i] = R["sn"]; P_k[i] = R["k"]; P_lang[i] = R["lang"]
      }
    }
    close(f)
    if (ok) return
  }
  close(f)
  # generic fallback
  readJ(f); PROOT = J[jp("$", "root")]; NFILES = JN[jp("$", "files")]; NPIECES = JN[jp("$", "pieces")]
  for (i = 0; i < NFILES; i++) { p = jp(jp("$", "files"), i); FL_rel[i] = J[jp(p, "rel")]; FL_h[i] = J[jp(p, "h")] }
  for (i = 0; i < NPIECES; i++) {
    p = jp(jp("$", "pieces"), i); np = J[jp(p, "i")] + 0
    P_f[np] = J[jp(p, "f")] + 0; P_s[np] = J[jp(p, "s")] + 0; P_e[np] = J[jp(p, "e")] + 0; P_hp[np] = J[jp(p, "hp")]; P_sn[np] = J[jp(p, "sn")]
    P_k[np] = (jp(p, "k") in J) ? J[jp(p, "k")] : ""; P_lang[np] = (jp(p, "lang") in J) ? J[jp(p, "lang")] : ""
  }
}
function loadGroups(   f, k, base, fp, wpth, j) {
  if (GLOADED) return
  GLOADED = 1; f = wp("groups.json"); readJ(f)
  GN = JN["$"]
  for (k = 1; k <= GN; k++) {
    base = jp("$", k - 1); GG[k] = J[jp(base, "g")] + 0
    fp = jp(base, "files"); GNF[k] = JN[fp]
    for (j = 1; j <= GNF[k]; j++) GFILE[k, j] = J[jp(fp, j - 1)]
    wpth = jp(base, "windows"); GNW[k] = JN[wpth]
    for (j = 1; j <= GNW[k]; j++) { GWN[k, j] = J[jp(jp(wpth, j - 1), "w")] + 0; GWF[k, j] = J[jp(jp(wpth, j - 1), "from")] + 0; GWT[k, j] = J[jp(jp(wpth, j - 1), "to")] + 0 }
  }
}
function findGroup(s,   k) { if (!jsnumber(s)) return 0; for (k = 1; k <= GN; k++) if (GG[k] == NUMV) return k; return 0 }
function findWindow(gi, s,   j) { if (!jsnumber(s)) return 0; for (j = 1; j <= GNW[gi]; j++) if (GWN[gi, j] == NUMV) return j; return 0 }

function outFile(g, w) { return wp("out/g" g "-w" w ".txt") }
function sumFile(g, w) { return wp("out/g" g "-w" w ".sum") }
# OUTID/OUTOK/OUTPATH/OUTDESC[1..OUTN]; returns -1 when the file does not exist
function readOut(g, w,   raw, n, A, i, l, k, rest, k2, idtxt) {
  raw = slurp(outFile(g, w))
  if (!SL_OK) return -1
  OUTN = 0; n = split(raw, A, "\n")
  for (i = 1; i <= n; i++) {
    l = trim(A[i]); if (l == "") continue
    OUTN++
    k = index(l, ";")
    if (k == 0) { idtxt = substr(l, 1, length(l) - 1); rest = l } else { idtxt = substr(l, 1, k - 1); rest = substr(l, k + 1) }
    k2 = index(rest, ";")
    OUTPATH[OUTN] = trim(k2 ? substr(rest, 1, k2 - 1) : rest); OUTDESC[OUTN] = k2 ? trim(substr(rest, k2 + 1)) : ""
    if (jsnumber(idtxt)) { OUTID[OUTN] = jsnum(NUMV); OUTOK[OUTN] = isint(NUMV); OUTNUM[OUTN] = NUMV } else { OUTID[OUTN] = "NaN"; OUTOK[OUTN] = 0; OUTNUM[OUTN] = 0 }
  }
  return OUTN
}
function segsOk(s,   w) { w = W(s); return w >= 2 && w <= 4 && index(s, ";") == 0 }

# ---------------- window ----------------
function cmdWindow(   gi, wi, g, w, from, to, prevSum, k, n, r, S, ns, d, p, nv, vk, i, out, sum, hasCode, head, tail, vl, nvl, lastF, lastHp, pc, rawsum, t, VC) {
  loadGroups(); gi = findGroup(POS[1]); if (!gi) die("no such group")
  wi = findWindow(gi, POS[2]); if (!wi) die("no such window")
  g = GG[gi]; w = GWN[gi, wi]; from = GWF[gi, wi]; to = GWT[gi, wi]
  loadPieces()
  prevSum = ""
  if (w > 1) { rawsum = slurp(sumFile(g, w - 1)); if (SL_OK) prevSum = trim(rawsum) }
  nv = 0
  for (k = 1; k < w; k++) {
    n = readOut(g, k); if (n < 0) continue
    for (r = 1; r <= n; r++) {
      ns = split(OUTPATH[r], S, "/") - 1
      for (d = 1; d <= (ns < 3 ? ns : 3); d++) {
        p = S[1]; for (i = 2; i <= d; i++) p = p "/" S[i]
        if (!(p in VC)) { VC[p] = 0; vk[++nv] = p }
        VC[p]++
      }
    }
  }
  nvl = sortkeys(vk, nv)
  if (nvl > 160) { n = 0; for (i = 1; i <= nvl; i++) if (split(SORTED[i], S, "/") <= 2) VL[++n] = SORTED[i]; else continue; nvl = n; for (i = 1; i <= nvl; i++) SORTED[i] = VL[i] }
  hasCode = 0; for (i = from; i <= to; i++) if (P_k[i] == "c") { hasCode = 1; break }
  head = tpl("window-head.txt")
  head = subst(head, "G", g); head = subst(head, "W", w); head = subst(head, "NW", GNW[gi]); head = subst(head, "FROM", from); head = subst(head, "TO", to)
  head = subst(head, "DESCFMT", hasCode ? "[;<description> for code pieces]" : "")
  printf "%s", head
  if (hasCode) printf "%s", tpl("window-code.txt")
  tail = tpl("window-tail.txt")
  tail = subst(tail, "OUT", q(resolvep(outFile(g, w)))); tail = subst(tail, "SUM", q(resolvep(sumFile(g, w))))
  tail = subst(tail, "RUN", RUN); tail = subst(tail, "G", g); tail = subst(tail, "W", w); tail = subst(tail, "WORKQ", WORKQ)
  tail = subst(tail, "PREV", prevSum == "" ? "(first window)" : prevSum)
  t = ""
  if (nvl) { for (i = 1; i <= nvl; i++) t = t (i > 1 ? "\n" : "") SORTED[i] " (" VC[SORTED[i]] ")" } else t = "(none yet)"
  tail = subst(tail, "VOCAB", t)
  printf "%s", tail
  lastF = -1; lastHp = ""; lastHpSet = 0
  for (i = from; i <= to; i++) {
    if (P_f[i] != lastF) { print "\n## FILE " FL_rel[P_f[i]]; lastF = P_f[i]; lastHpSet = 0 }
    if (P_k[i] == "c") { print i " [code " P_lang[i] "] " P_sn[i]; continue }
    if (!lastHpSet || P_hp[i] != lastHp) { print "# " (P_hp[i] == "" ? "(no heading)" : P_hp[i]); lastHp = P_hp[i]; lastHpSet = 1 }
    print i " " P_sn[i]
  }
}

# ---------------- check ----------------
function adderr(m) { NERR++; ERRS[NERR] = m }
function checkWindow(gi, wi,   g, w, from, to, n, r, seen, paths, pathid, pord, np, S, ns, x, id, miss, nm, ml, i, dw, p, sraw, pr, found) {
  NERR = 0; g = GG[gi]; w = GWN[gi, wi]; from = GWF[gi, wi]; to = GWT[gi, wi]
  n = readOut(g, w)
  if (n < 0) { adderr(outFile(g, w) " not found"); return }
  np = 0
  for (r = 1; r <= n; r++) {
    id = OUTID[r]
    if (!OUTOK[r] || OUTNUM[r] < from || OUTNUM[r] > to) { adderr("line " r ": bad id \"" id "\" (need " from "-" to ", format id;path)"); BADID[r] = 1; continue }
    BADID[r] = 0
    if (id in seen) adderr("id " id " appears twice")
    seen[id] = 1
    ns = split(OUTPATH[r], S, "/")
    if (ns < 2 || ns > 6) adderr("id " id ": depth " ns " (need 3-5 segments, minimum 2)")
    for (x = 1; x <= ns; x++) if (!segsOk(S[x])) adderr("id " id ": segment \"" S[x] "\" must be 2-4 words")
    if (P_k[OUTNUM[r]] == "c") {
      dw = W(OUTDESC[r])
      if (OUTDESC[r] == "") adderr("id " id ": code piece needs a description (id;path;description)")
      else if (dw > 45) adderr("id " id ": description has " dw " words (max 40)")
    }
    if (OUTPATH[r] in pathid) adderr("id " id ": path duplicates id " pathid[OUTPATH[r]] " (\"" OUTPATH[r] "\")")
    else { np++; pord[np] = OUTPATH[r] }
    pathid[OUTPATH[r]] = id
  }
  for (r = 1; r <= n; r++) {
    pr = OUTPATH[r] "/"; ml = length(pr)
    for (i = 1; i <= np; i++) if (substr(pord[i], 1, ml) == pr) { adderr("id " OUTID[r] ": path \"" OUTPATH[r] "\" is also a prefix of id " pathid[pord[i]] "'s path"); break }
  }
  nm = 0; ml = ""
  for (i = from; i <= to; i++) if (!(i in seen)) { nm++; if (nm <= 20) ml = ml (nm > 1 ? "," : "") i }
  if (nm) adderr(nm " ids missing: " ml (nm > 20 ? "\342\200\246" : ""))
  sraw = slurp(sumFile(g, w))
  if (!SL_OK) adderr("summary file " sumFile(g, w) " missing")
  else if (W(sraw) > 120) adderr("summary longer than 120 words")
}
function cmdCheck(   gi, wi) {
  loadGroups(); loadPieces()
  gi = findGroup(POS[1]); wi = gi ? findWindow(gi, POS[2]) : 0
  if (!gi || !wi) die("TypeError: Cannot read properties of undefined")
  checkWindow(gi, wi)
  if (NERR) {
    for (i = 1; i <= NERR && i <= 40; i++) print "ERROR: " ERRS[i]
    if (NERR > 40) print "\342\200\246 " (NERR - 40) " more"
    exit 1
  }
  print "OK"
}
function cmdCheckAll(   gi, wi, nb, bg, bw, bf, out, i) {
  loadGroups(); loadPieces(); nb = 0
  for (gi = 1; gi <= GN; gi++) for (wi = 1; wi <= GNW[gi]; wi++) {
    checkWindow(gi, wi)
    if (NERR) { nb++; bg[nb] = GG[gi]; bw[nb] = GWN[gi, wi]; bf[nb] = ERRS[1] }
  }
  out = "{\"failing\":["
  for (i = 1; i <= nb; i++) out = out (i > 1 ? "," : "") "{\"g\":" bg[i] ",\"w\":" bw[i] "}"
  out = out "],\"detail\":["
  for (i = 1; i <= nb && i <= 10; i++) out = out (i > 1 ? "," : "") "{\"g\":" bg[i] ",\"w\":" bw[i] ",\"first\":" jstr(bf[i]) "}"
  print out "]}"
}
function cmdStatus(   gi, wi, d, done, tot, n, out) {
  loadGroups(); done = 0; tot = 0; out = ""
  for (gi = 1; gi <= GN; gi++) {
    d = 0
    for (wi = 1; wi <= GNW[gi]; wi++) {
      tot++; n = readOut(GG[gi], GWN[gi, wi])
      if (n >= 0 && n == GWT[gi, wi] - GWF[gi, wi] + 1 && fileexists(sumFile(GG[gi], GWN[gi, wi]))) { d++; done++ }
    }
    out = out "group " GG[gi] ": " d "/" GNW[gi] " windows\n"
  }
  print out done "/" tot " windows done"
}

# ---------------- group rows / merge ----------------
# all outline rows of group index gi into GR_id/GR_path/GR_desc[1..GRN] (windows in order)
function groupRows(gi,   wi, n, r) {
  GRN = 0
  for (wi = 1; wi <= GNW[gi]; wi++) {
    n = readOut(GG[gi], GWN[gi, wi])
    for (r = 1; r <= n; r++) { GRN++; GR_id[GRN] = OUTID[r]; GR_num[GRN] = OUTNUM[r]; GR_path[GRN] = OUTPATH[r]; GR_desc[GRN] = OUTDESC[r] }
  }
}
function lastSum(gi,   wi, last, raw) {
  last = 0
  for (wi = 1; wi <= GNW[gi]; wi++) if (fileexists(sumFile(GG[gi], GWN[gi, wi]))) last = wi
  if (!last) return ""
  raw = slurp(sumFile(GG[gi], GWN[gi, last])); return trim(raw)
}
function cmdMergeInput(   gi, i, r, S, ns, top, tn, tord, tcnt, subn, subk, subc, line, out, j, ch, ksub, first) {
  loadGroups()
  for (gi = 1; gi <= GN; gi++) { groupRows(gi); if (!GRN) die("group " GG[gi] " has no output yet") }
  t = tpl("merge.txt"); t = subst(t, "MERGE", q(wp("merge.txt"))); t = subst(t, "RUN", RUN); t = subst(t, "WORKQ", WORKQ)
  printf "%s", t
  first = 1
  for (gi = 1; gi <= GN; gi++) {
    groupRows(gi)
    if (!GRN) die("group " GG[gi] " has no output yet")
    delete tcnt; delete tord; delete subn; delete subk; delete subc; tn = 0
    for (r = 1; r <= GRN; r++) {
      ns = split(GR_path[r], S, "/"); top = S[1]
      if (!(top in tcnt)) { tcnt[top] = 0; tord[++tn] = top; subn[top] = 0 }
      tcnt[top]++
      if (ns > 2) { if (!((top, S[2]) in subc)) { subc[top, S[2]] = 0; subk[top, ++subn[top]] = S[2] } subc[top, S[2]]++ }
    }
    line = "### GROUP " GG[gi] "  (" GNF[gi] " files: "
    for (j = 1; j <= GNF[gi] && j <= 3; j++) line = line (j > 1 ? ", " : "") GFILE[gi, j]
    line = line (GNF[gi] > 3 ? ", \342\200\246" : "") "; " GRN " pieces)\nSummary: " lastSum(gi)
    print (first ? "" : "\n") line
    first = 0
    for (i = 1; i <= tn; i++) {
      top = tord[i]; ch = ""
      for (j = 1; j <= subn[top] && j <= 8; j++) ch = ch (j > 1 ? ", " : "") subk[top, j] " (" subc[top, subk[top, j]] ")"
      print GG[gi] ";" top "   [" tcnt[top] " pieces]  children: " ch
    }
  }
}

function treeRows(   f, raw, n, A, i, a, k) {
  if (!fileexists(wp("tree.paths"))) die("run apply-merge first")
  raw = slurp(wp("tree.paths")); TRN = 0; n = split(raw, A, "\n")
  for (i = 1; i <= n; i++) {
    if (A[i] == "") continue
    TRN++; k = split(A[i], a, ";")
    TR_g[TRN] = jsnumber(a[1]) ? jsnum(NUMV) : "NaN"; TR_path[TRN] = a[2]; TR_range[TRN] = a[3]
  }
}
function pieceRange(id) { return FL_rel[P_f[id]] ":" P_s[id] "-" P_e[id] }
function join(S, a, b,   i, o) { o = S[a]; for (i = a + 1; i <= b; i++) o = o "/" S[i]; return o }

function cmdApplyMerge(n, i, A, a, k, key, ne, ns, S, t, p, nn, last, nparts, parts, d, x, y, w, j, f, par, ch, nw, line, nl, kn, rawm) {
  if (fileexists(wp("reshape.applied")) && ENVIRON["WB_FORCE"] != "1") die("ERROR: reshape results were already applied to tree.paths; re-running apply-merge would discard them. Pass --force only if you want to start the reshape phase over (and delete " wp("reshape.applied") ").")
  loadGroups(); loadPieces()
  rawm = slurp(wp("merge.txt"))
  if (!SL_OK) die("ERROR: merge.txt not found")
  n = split(rawm, A, "\n"); nm = 0
  for (i = 1; i <= n; i++) {
    t = trim(A[i]); if (t == "") continue
    nm++; k = split(t, a, ";")
    mg[nm] = jsnumber(a[1]) ? jsnum(NUMV) : "NaN"; mt[nm] = trim(a[2])
    mp[nm] = ""; for (x = 3; x <= k; x++) mp[nm] = mp[nm] (x > 3 ? ";" : "") a[x]
    mp[nm] = trim(mp[nm])
  }
  ne = 0; nk = 0
  for (i = 1; i <= nm; i++) {
    key = mg[i] ";" mt[i]
    if (key in MAPV) ne = adde(errs, ne, "duplicate mapping for " key)
    else { nk++; MAPK[nk] = key }
    MAPV[key] = mp[i]
    ns = split(mp[i], S, "/"); ok = 1
    for (x = 1; x <= ns; x++) if (!segsOk(S[x])) ok = 0
    if (mp[i] == "" || ns > 2 || !ok) ne = adde(errs, ne, "bad prefix \"" mp[i] "\" for " key " (1-2 segments of 2-4 words)")
  }
  rowsN = 0
  for (gi = 1; gi <= GN; gi++) {
    groupRows(gi)
    delete topseen; nt = 0
    for (i = 1; i <= GRN; i++) { split(GR_path[i], S, "/"); if (!(S[1] in topseen)) { topseen[S[1]] = 1; tops_ord[++nt] = S[1] } }
    for (i = 1; i <= nt; i++) if (!((GG[gi] ";" tops_ord[i]) in MAPV)) ne = adde(errs, ne, "missing mapping for " GG[gi] ";" tops_ord[i])
    for (i = 1; i <= GRN; i++) {
      ns = split(GR_path[i], S, "/"); key = GG[gi] ";" S[1]
      if (key in MAPV && MAPV[key] != "") {
        rowsN++; RW_g[rowsN] = GG[gi]; RW_id[rowsN] = GR_num[i]; RW_path[rowsN] = MAPV[key] "/" (ns > 1 ? join(S, 2, ns) : ""); RW_desc[rowsN] = GR_desc[i]
      }
    }
  }
  delete topfin; nt = 0
  for (i = 1; i <= nk; i++) { ns = split(MAPV[MAPK[i]], S, "/"); if (!(S[1] in topfin)) { topfin[S[1]] = 1; nt++; TOPL[nt] = S[1] } }
  if (nt < 3 || nt > 8) { line = ""; for (i = 1; i <= nt; i++) line = line (i > 1 ? " | " : "") TOPL[i]; ne = adde(errs, ne, "final tree has " nt " top-level branches (need 3-8): " line) }
  if (ne) { for (i = 1; i <= ne && i <= 30; i++) print "ERROR: " errs_[i]; exit 1 }
  # stable sort by id
  for (i = 2; i <= rowsN; i++) {
    x = RW_id[i]; y = RW_path[i]; w = RW_desc[i]; k = RW_g[i]; j = i - 1
    while (j >= 1 && RW_id[j] > x) { RW_id[j + 1] = RW_id[j]; RW_path[j + 1] = RW_path[j]; RW_desc[j + 1] = RW_desc[j]; RW_g[j + 1] = RW_g[j]; j-- }
    RW_id[j + 1] = x; RW_path[j + 1] = y; RW_desc[j + 1] = w; RW_g[j + 1] = k
  }
  for (i = 1; i <= rowsN; i++) { ns = split(RW_path[i], S, "/"); for (d = 1; d < ns; d++) prefixes[join(S, 1, d)] = 1 }
  fixes = 0
  for (i = 1; i <= rowsN; i++) {
    p = RW_path[i]; nn = 1
    while ((p in used) || (p in prefixes)) {
      nn++; ns = split(RW_path[i], S, "/"); last = S[ns]
      nparts = split(last, parts, /[ ]/)
      if (nparts >= 4) last = parts[1] " " parts[2] " " parts[3]
      p = ""; for (d = 1; d < ns; d++) p = p S[d] "/"
      p = p last " " nn
    }
    if (p != RW_path[i]) { fixes++; RW_path[i] = p }
    used[p] = 1
  }
  f = wp("tree.paths")
  if (rowsN == 0) printf "\n" > f
  for (i = 1; i <= rowsN; i++) printf "%s;%s;%s\n", RW_g[i], RW_path[i], pieceRange(RW_id[i]) > f
  close(f)
  f = wp("leafdesc.json"); printf "{" > f; nl = 0
  for (i = 1; i <= rowsN; i++) if (P_k[RW_id[i]] == "c" && RW_desc[i] != "") { printf "%s%s:%s", (nl ? "," : ""), jstr(pieceRange(RW_id[i])), jstr(RW_desc[i]) > f; nl++ }
  printf "}" > f; close(f)
  # width report
  kn = 0
  for (i = 1; i <= rowsN; i++) {
    ns = split(RW_path[i], S, "/")
    for (d = 0; d < ns; d++) {
      par = (d == 0) ? "" : join(S, 1, d); ch = S[d + 1]
      if (!(par in kcnt)) { kcnt[par] = 0; kn++; kord[kn] = par }
      if (!((par, ch) in kchild)) { kchild[par, ch] = 1; kcnt[par]++ }
    }
  }
  nw = 0
  for (i = 1; i <= kn; i++) if (kcnt[kord[i]] > 9) { nw++; wide[nw] = kord[i] }
  for (i = 2; i <= nw; i++) { x = wide[i]; j = i - 1; while (j >= 1 && kcnt[wide[j]] < kcnt[x]) { wide[j + 1] = wide[j]; j-- } wide[j + 1] = x }
  print "OK  " rowsN " pieces, " nt " top-level branches" (fixes ? ", " fixes " path collisions auto-renamed" : "")
  if (nw) {
    line = ""
    for (i = 1; i <= nw && i <= 8; i++) line = line (i > 1 ? "; " : "") (wide[i] == "" ? "(root)" : wide[i]) ": " kcnt[wide[i]]
    print nw " branches have >9 children (worst: " line ")"
  }
}
function adde(arr, n, m) { n++; errs_[n] = m; return n }

# ---------------- describe ----------------
function cmdDescribeInput(   gi, g, i, S, ns, d, p, bn, bk, bcnt, bch, bchn, bchs, nb, j, line, t, ch) {
  loadGroups(); treeRows()
  if (!jsnumber(POS[1])) g = "NaN"; else g = jsnum(NUMV)
  nb = 0
  for (i = 1; i <= TRN; i++) {
    if (TR_g[i] != g) continue
    ns = split(TR_path[i], S, "/")
    for (d = 1; d < ns && d <= 3; d++) {
      p = join(S, 1, d)
      if (!(p in bcnt)) { bcnt[p] = 0; bchn[p] = 0; nb++; bk[nb] = p }
      bcnt[p]++
      if (!((p, S[d + 1]) in bchs)) { bchs[p, S[d + 1]] = 1; bchn[p]++; bch[p, bchn[p]] = S[d + 1] }
    }
  }
  nb = sortkeys(bk, nb)
  t = tpl("describe.txt"); t = subst(t, "DESCF", q(wp("desc/g" g ".txt"))); t = subst(t, "RUN", RUN); t = subst(t, "G", g); t = subst(t, "WORKQ", WORKQ); t = subst(t, "NB", nb)
  printf "%s", t
  for (i = 1; i <= nb; i++) {
    p = SORTED[i]; ch = ""
    for (j = 1; j <= bchn[p] && j <= 8; j++) ch = ch (j > 1 ? ", " : "") bch[p, j]
    print p "   [" bcnt[p] " pieces]  children: " ch
  }
}
function cmdCheckDesc(   g, f, raw, i, n, A, l, k, key, val, need, nneed, S, ns, d, p, got, gord, ng, ne, rows) {
  if (!jsnumber(POS[1])) g = "NaN"; else g = jsnum(NUMV)
  f = wp("desc/g" g ".txt")
  raw = slurp(f); if (!SL_OK) die("ERROR: " f " not found")
  treeRows()
  nneed = 0
  for (i = 1; i <= TRN; i++) {
    if (TR_g[i] != g) continue
    ns = split(TR_path[i], S, "/")
    for (d = 1; d < ns && d <= 3; d++) { p = join(S, 1, d); if (!(p in need)) { need[p] = 1; nneed++; NEEDL[nneed] = p } }
  }
  n = split(raw, A, "\n"); ng = 0
  for (i = 1; i <= n; i++) {
    l = A[i]; if (trim(l) == "") continue
    k = index(l, ";")
    if (k == 0) { key = trim(substr(l, 1, length(l) - 1)); val = trim(l) } else { key = trim(substr(l, 1, k - 1)); val = trim(substr(l, k + 1)) }
    if (!(key in got)) { ng++; gord[ng] = key }
    got[key] = val
  }
  ne = 0
  for (i = 1; i <= nneed; i++) if (got[NEEDL[i]] == "") ne = adde(errs, ne, "missing description for \"" NEEDL[i] "\"")
  for (i = 1; i <= ng; i++) { p = gord[i]; if (!(p in need)) ne = adde(errs, ne, "unknown branch \"" p "\""); else if (W(got[p]) > 30) ne = adde(errs, ne, "description too long for \"" p "\"") }
  if (ne) { for (i = 1; i <= ne && i <= 30; i++) print "ERROR: " errs_[i]; exit 1 }
  print "OK"
}

# ---------------- ordered description map (JS Map semantics) ----------------
function dmclear() { delete DMV; delete DMI; DMN = 0; DMLIVE = 0 }
function dmset(k, v) { if (k in DMI) DMV[DMI[k]] = v; else { DMN++; DMK[DMN] = k; DMV[DMN] = v; DMI[k] = DMN } }
function dmhas(k) { return k in DMI }
function dmget(k) { return DMV[DMI[k]] }
function dmsize() { return DMN }
function loadDesc(   all, dir, cmd, line, files, nf, i, f, raw, n, A, j, l, k, key, tmp, ntmp) {
  dmclear()
  all = wp("desc/_all.txt"); nf = 0
  if (fileexists(all)) { nf = 1; files[1] = all }
  else if (system("test -d " shq(wp("desc"))) == 0) {
    cmd = "ls -1 " shq(wp("desc")) " | sort"
    while ((cmd | getline line) > 0) if (line ~ /^g[0-9]+\.txt$/) files[++nf] = wp("desc/" line)
    close(cmd)
  }
  for (i = 1; i <= nf; i++) {
    raw = slurp(files[i]); n = split(raw, A, "\n")
    for (j = 1; j <= n; j++) {
      l = A[j]; if (trim(l) == "") continue
      k = index(l, ";")
      if (k == 0) { key = trim(substr(l, 1, length(l) - 1)); if (!dmhas(key)) dmset(key, trim(l)) }
      else { key = trim(substr(l, 1, k - 1)); if (!dmhas(key)) dmset(key, trim(substr(l, k + 1))) }
    }
  }
}
function saveDesc(   f, i) {
  f = wp("desc/_all.txt")
  if (DMN == 0) printf "\n" > f
  for (i = 1; i <= DMN; i++) printf "%s;%s\n", DMK[i], DMV[i] > f
  close(f)
}

# ---------------- reshape ----------------
# WK[par, child] = piece count, WLF[par, child] = leaf flag, WKN[par] = number of children, WKC[par, i] = child title, WPAR[1..WPN] parents in first-seen order
function widths(   i, S, ns, d, par) {
  delete WK; delete WLF; delete WKN; delete WKC; delete WPI; WPN = 0
  for (i = 1; i <= TRN; i++) {
    ns = split(TR_path[i], S, "/")
    for (d = 1; d < ns; d++) {
      par = join(S, 1, d)
      if (!(par in WPI)) { WPI[par] = 1; WPN++; WPAR[WPN] = par; WKN[par] = 0 }
      if (!((par, S[d + 1]) in WK)) { WK[par, S[d + 1]] = 0; WKN[par]++; WKC[par, WKN[par]] = S[d + 1] }
      WK[par, S[d + 1]]++; WLF[par, S[d + 1]] = (d == ns - 1)
    }
  }
}
function loadWide(   i, p) {
  if (WLOADED) return
  WLOADED = 1; readJ(wp("wide.json")); NWIDE = JN["$"]
  for (i = 1; i <= NWIDE; i++) { p = jp("$", i - 1); WIDE_path[i] = J[jp(p, "path")]; WIDE_n[i] = J[jp(p, "n")] + 0 }
}
function cmdReshapeList(   i, nw, wide, S, x, j, ord, f, out, k, cnt) {
  treeRows(); widths(); nw = 0
  for (i = 1; i <= WPN; i++) if (WKN[WPAR[i]] > 9) { nw++; wide[nw] = WPAR[i] }
  nw = sortkeys(wide, nw)
  for (i = 1; i <= nw; i++) { WIDE_path[i] = SORTED[i]; WIDE_n[i] = WKN[SORTED[i]] }
  f = wp("wide.json"); printf "[" > f
  for (i = 1; i <= nw; i++) printf "%s{\"path\":%s,\"n\":%d}", (i > 1 ? "," : ""), jstr(WIDE_path[i]), WIDE_n[i] > f
  printf "]" > f; close(f)
  for (i = 1; i <= nw; i++) ord[i] = i
  for (i = 2; i <= nw; i++) { x = ord[i]; j = i - 1; while (j >= 1 && WIDE_n[ord[j]] < WIDE_n[x]) { ord[j + 1] = ord[j]; j-- } ord[j + 1] = x }
  out = "{\"count\":" nw ",\"worst\":["
  for (i = 1; i <= nw && i <= 5; i++) out = out (i > 1 ? "," : "") "{\"path\":" jstr(WIDE_path[ord[i]]) ",\"n\":" WIDE_n[ord[i]] "}"
  print out "]}"
}
function cmdReshapeCount(   i, c) {
  treeRows(); widths(); c = 0
  for (i = 1; i <= WPN; i++) if (WKN[WPAR[i]] > 9) c++
  print "{\"count\":" c ",\"readOnly\":true}"
}
function cmdReshapeInput(   n, wpth, i, S, ns, c, rest, chn, chk, chcnt, chleaf, chsub, chnsub, chsn, k, ld, key, rg, pc, t, out, sn, a, na, j, hasld, byStart, e, m, line) {
  loadWide(); loadPieces()
  n = (jsnumber(POS[1]) ? NUMV : -1)
  if (n < 1 || n > NWIDE || n != int(n)) die("no such wide branch")
  wpth = WIDE_path[n]
  treeRows()
  hasld = fileexists(wp("leafdesc.json")); if (hasld) readJ(wp("leafdesc.json"))
  for (i = 1; i <= NPIECES; i++) byStart[FL_rel[P_f[i]] ":" P_s[i]] = i
  chn = 0; ml = length(wpth) + 1
  for (i = 1; i <= TRN; i++) {
    if (substr(TR_path[i], 1, ml) != wpth "/") continue
    rest = substr(TR_path[i], ml + 1); ns = split(rest, S, "/"); c = S[1]
    if (!(c in chcnt)) { chcnt[c] = 0; chn++; chk[chn] = c; chleaf[c] = (ns == 1); chsn[c] = ""; chnsub[c] = 0 }
    chcnt[c]++
    if (ns > 1) {
      chleaf[c] = 0
      if (chnsub[c] < 3) { found = 0; for (j = 1; j <= chnsub[c]; j++) if (chsub[c, j] == S[2]) found = 1; if (!found) { chnsub[c]++; chsub[c, chnsub[c]] = S[2] } }
    } else {
      rg = TR_range[i]; key = substr(rg, 1, rindex_(rg, "-") - 1); sn = ""
      if (hasld && (jp("$", rg) in J) && J[jp("$", rg)] != "") sn = J[jp("$", rg)]
      else if (key in byStart && P_k[byStart[key]] != "c") { na = split(P_sn[byStart[key]], a, /[ ]/); for (j = 1; j <= na && j <= 14; j++) sn = sn (j > 1 ? " " : "") a[j] }
      chsn[c] = sn
    }
  }
  t = tpl("reshape.txt"); t = subst(t, "PATH", wpth); t = subst(t, "NCH", chn); t = subst(t, "RF", q(wp("reshape/r" n ".txt"))); t = subst(t, "RUN", RUN); t = subst(t, "N", n); t = subst(t, "WORKQ", WORKQ)
  printf "%s", t
  for (i = 1; i <= chn; i++) {
    c = chk[i]
    if (chleaf[c]) print c "   [piece] " chsn[c]
    else { line = ""; for (j = 1; j <= chnsub[c]; j++) line = line (j > 1 ? ", " : "") chsub[c, j]; print c "   [branch, " chcnt[c] " pieces] " line }
  }
}
function rindex_(s, ch,   i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == ch) return i; return 0 }

# reshape/rN.txt rows into RR_child/RR_group/RR_desc[1..RRN]; returns -1 when the file does not exist
function readReshape(n,   raw, A, na, i, l, a, k, x) {
  raw = slurp(wp("reshape/r" n ".txt")); if (!SL_OK) return -1
  RRN = 0; na = split(raw, A, "\n")
  for (i = 1; i <= na; i++) {
    l = trim(A[i]); if (l == "") continue
    RRN++; k = split(l, a, ";")
    RR_child[RRN] = trim(a[1]); RR_group[RRN] = trim(a[2]); RR_desc[RRN] = ""
    for (x = 3; x <= k; x++) RR_desc[RRN] = RR_desc[RRN] (x > 3 ? ";" : "") a[x]
    RR_desc[RRN] = trim(RR_desc[RRN])
  }
  return RRN
}
function cmdCheckReshape(   n, wpth, nr, i, ne, seen, gcnt, ngr, gord, c, gtitle, j) {
  loadWide()
  n = (jsnumber(POS[1]) ? NUMV : -1)
  nr = readReshape(n)
  if (nr < 0) die("ERROR: reshape file r" n ".txt not found")
  if (n < 1 || n > NWIDE) die("TypeError: Cannot read properties of undefined (reading 'path')")
  wpth = WIDE_path[n]; treeRows(); widths()
  ne = 0; ngr = 0
  for (i = 1; i <= nr; i++) {
    c = RR_child[i]; gtitle = RR_group[i]
    if (!((wpth, c) in WK)) { ne = adde(errs, ne, "unknown child \"" c "\""); continue }
    if (c in seen) ne = adde(errs, ne, "child \"" c "\" appears twice")
    seen[c] = 1
    if (!segsOk(gtitle) || index(gtitle, "/") > 0) ne = adde(errs, ne, "group title \"" gtitle "\" must be 2-4 words without ; or /")
    if ((wpth, gtitle) in WK) ne = adde(errs, ne, "group title \"" gtitle "\" equals an existing child title")
    if (!(gtitle in gcnt)) { gcnt[gtitle] = 0; ngr++ }
    gcnt[gtitle]++
  }
  for (j = 1; j <= WKN[wpth]; j++) if (!(WKC[wpth, j] in seen)) ne = adde(errs, ne, "child \"" WKC[wpth, j] "\" missing")
  if (ngr < 2) ne = adde(errs, ne, "need at least 2 groups")
  if (ngr > 9) ne = adde(errs, ne, "at most 9 groups")
  if (ne) { for (i = 1; i <= ne && i <= 30; i++) print "ERROR: " errs_[i]; exit 1 }
  print "OK"
}
function cmdApplyReshape(   i, nw, ord, x, j, w, wpth, nr, cmap, ml, rest, S, ns, g, k, v, ndn, applied, skipped, still, f, depth, ndk, ndv) {
  treeRows(); loadWide(); loadDesc(); applied = 0; skipped = 0
  nw = NWIDE
  for (i = 1; i <= nw; i++) { ord[i] = i; depth[i] = split(WIDE_path[i], S, "/") }
  for (i = 2; i <= nw; i++) { x = ord[i]; j = i - 1; while (j >= 1 && depth[ord[j]] < depth[x]) { ord[j + 1] = ord[j]; j-- } ord[j + 1] = x }
  for (i = 1; i <= nw; i++) {
    w = ord[i]; wpth = WIDE_path[w]
    nr = readReshape(w)
    if (nr < 0) { skipped++; continue }
    delete cmap
    for (j = 1; j <= nr; j++) cmap[RR_child[j]] = RR_group[j]
    ml = length(wpth) + 1
    for (j = 1; j <= TRN; j++) if (substr(TR_path[j], 1, ml) == wpth "/") {
      rest = substr(TR_path[j], ml + 1); ns = split(rest, S, "/"); g = cmap[S[1]]
      if (g != "") TR_path[j] = wpth "/" g "/" rest
    }
    ndn = 0
    for (j = 1; j <= DMN; j++) {
      k = DMK[j]; v = DMV[j]
      if (substr(k, 1, ml) == wpth "/") { rest = substr(k, ml + 1); split(rest, S, "/"); g = cmap[S[1]]; ndn++; ndk[ndn] = (g != "" ? wpth "/" g "/" rest : k); ndv[ndn] = v }
      else { ndn++; ndk[ndn] = k; ndv[ndn] = v }
    }
    dmclear()
    for (j = 1; j <= ndn; j++) dmset(ndk[j], ndv[j])
    for (j = 1; j <= nr; j++) if (RR_desc[j] != "" && !dmhas(wpth "/" RR_group[j])) dmset(wpth "/" RR_group[j], RR_desc[j])
    applied++
  }
  f = wp("tree.paths")
  if (TRN == 0) printf "\n" > f
  for (i = 1; i <= TRN; i++) printf "%s;%s;%s\n", TR_g[i], TR_path[i], TR_range[i] > f
  close(f)
  saveDesc()
  if (applied) { printf "1" > wp("reshape.applied"); close(wp("reshape.applied")) }
  widths(); still = 0
  for (i = 1; i <= WPN; i++) if (WKN[WPAR[i]] > 9) still++
  print "OK  reshaped " applied " branches" (skipped ? ", " skipped " had no result" : "") "; " still " branches still wider than 9"
}

function cmdGroupsArgs(   k, out) {
  loadGroups()
  out = "{\"work\":" jstr(WORK) ",\"cli\":" jstr(SELFABS) ",\"run\":" jstr(RUN) ",\"groups\":["
  for (k = 1; k <= GN; k++) out = out (k > 1 ? "," : "") "{\"g\":" GG[k] ",\"windows\":" GNW[k] "}"
  print out "]}"
}
function cmdEstimate(   f) {
  readJ(wp("estimate.json"))
  printf "estimate: ~%s haiku agents, ~%sM tokens, ~%s min wall-clock (%s doc + %s code pieces, %s windows). Rough: real runs landed within 0.5x-2x.\n", J[jp("$", "agents")], J[jp("$", "tokensM")], J[jp("$", "minutes")], J[jp("$", "docPieces")], J[jp("$", "codePieces")], J[jp("$", "windows")]
}

# ---------------- build ----------------
function sha1file(abs,   cmd, line, a, k, n, r) {
  cmd = SHA " < " shq(abs); r = ""
  while ((cmd | getline line) > 0) { n = split(line, a, /[ =()]+/); for (k = 1; k <= n; k++) if (length(a[k]) == 40 && a[k] ~ /^[0-9a-f]+$/) r = a[k] }
  close(cmd)
  return r
}
function getlines(f,   raw, n, i) {
  if (f in FLN) return
  raw = slurp(PROOT "/" f)
  if (!SL_OK) die("Error: ENOENT: no such file or directory, open '" PROOT "/" f "'")
  n = jsplit(raw, TMPA)
  FLN[f] = n
  for (i = 1; i <= n; i++) FLX[f, i] = TMPA[i]
}
function titleOf(root,   b, o, i, c, prev, u) {
  b = basenamep(root)
  gsub(/[-_]+/, " ", b)
  o = ""; prev = " "
  for (i = 1; i <= length(b); i++) {
    c = substr(b, i, 1)
    if (c ~ /[a-z]/ && prev !~ /[A-Za-z0-9_]/) c = toupper(c)
    o = o c; prev = substr(b, i, 1)
  }
  return o
}
function isFresh(f,   want) {
  if (!(f in FRESH)) { want = FHASH[f]; FRESH[f] = (want == "" || sha1file(PROOT "/" f) == want) }
  return FRESH[f]
}
function newnode(title, leaf,   i) { NN++; NT[NN] = title; NLEAF[NN] = leaf; NKF[NN] = 0; NKL[NN] = 0; NNX[NN] = 0; NDS[NN] = ""; return NN }
function addkid(par, kid) { if (NKL[par]) NNX[NKL[par]] = kid; else NKF[par] = kid; NKL[par] = kid }
function walkIds(i,   k) {
  NID[i] = NIDC++
  if (NLEAF[i]) {
    getlines(NFILE[i])
    if (!isFresh(NFILE[i])) { stale++; if (!(NFILE[i] in STF)) { STF[NFILE[i]] = 1; nstf++; STL[nstf] = NFILE[i] } }
  } else for (k = NKF[i]; k; k = NNX[k]) walkIds(k)
}
function leafText(i,   f, s, e, t, k) {
  f = NFILE[i]; s = NS[i]; e = NE[i]; if (e > FLN[f]) e = FLN[f]; t = ""
  for (k = s; k <= e; k++) t = t (k > s ? "\n" : "") FLX[f, k]
  return t
}
function emitJson(i, out,   k, line) {
  if (NLEAF[i]) {
    printf "{\"title\":%s,\"file\":%s,\"start\":%s,\"end\":%s", jstr(NT[i]), jstr(NFILE[i]), jsnum(NS[i]), jsnum(NE[i]) > out
    if (NCODE[i]) printf ",\"kind\":\"code\",\"lang\":%s,\"description\":%s", jstr(NLANG[i]), jstr(NDS[i]) > out
    printf ",\"id\":\"n%d\",\"text\":%s}", NID[i], jstr(leafText(i)) > out
  } else {
    printf "{\"title\":%s,\"children\":[", jstr(NT[i]) > out
    for (k = NKF[i]; k; k = NNX[k]) { if (k != NKF[i]) printf "," > out; emitJson(k, out) }
    printf "]" > out
    if (NHD[i]) printf ",\"description\":%s", jstr(NDS[i]) > out
    printf ",\"id\":\"n%d\"}", NID[i] > out
  }
}
function emitFlat(i, path, out,   k, p) {
  for (k = NKF[i]; k; k = NNX[k]) {
    p = (path == "" ? "" : path "/") NT[k]
    if (NLEAF[k]) { flatn++; printf "%s;%s;%s:%s-%s;%s\n", ((p in GOF) ? GOF[p] : ""), p, NFILE[k], jsnum(NS[k]), jsnum(NE[k]), (NCODE[k] ? NDS[k] : "") > out }
    else { flatn++; printf ";%s;;%s\n", p, (NHD[k] ? NDS[k] : "") > out; emitFlat(k, p, out) }
  }
}
function cmdBuild(   i, k, S, ns, d, par, seg, acc, node, c, dsc, rg, a, b, lc, rel, hasld, ld, key, root, ordr, title, outp, flat, nodes, p, ss) {
  treeRows(); loadPieces(); loadDesc()
  hasld = fileexists(wp("leafdesc.json")); if (hasld) readJ(wp("leafdesc.json"))
  for (i = 1; i <= NPIECES; i++) BYR[FL_rel[P_f[i]] ":" P_s[i] "-" P_e[i]] = i
  for (i = 0; i < NFILES; i++) FHASH[FL_rel[i]] = FL_h[i]
  title = titleOf(PROOT)
  NN = 0; root = newnode(title, 0)
  for (i = 1; i <= TRN; i++) {
    ns = split(TR_path[i], S, "/"); node = root; acc = ""
    for (d = 1; d <= ns; d++) {
      seg = S[d]; acc = (d > 1 ? acc "/" : "") seg
      if (d < ns) {
        if ((node, seg) in BRC) c = BRC[node, seg]
        else {
          c = newnode(seg, 0); BRC[node, seg] = c
          if (dmhas(acc) && dmget(acc) != "") { NHD[c] = 1; NDS[c] = dmget(acc) }
          addkid(node, c)
        }
        node = c
      } else {
        rg = TR_range[i]; lc = rindex_(rg, ":")
        c = newnode(seg, 1); NFILE[c] = substr(rg, 1, lc - 1)
        split(substr(rg, lc + 1), a, "-")
        NS[c] = jsnumber(a[1]) ? NUMV : 0; NE[c] = jsnumber(a[2]) ? NUMV : 0
        NCODE[c] = 0
        if ((rg in BYR) && P_k[BYR[rg]] == "c") {
          NCODE[c] = 1; NLANG[c] = P_lang[BYR[rg]]
          NDS[c] = (hasld && (jp("$", rg) in J)) ? J[jp("$", rg)] : ""
        }
        addkid(node, c)
      }
    }
  }
  NIDC = 0; stale = 0; nstf = 0
  walkIds(root)
  if (stale && ENVIRON["WB_ALLOWSTALE"] != "1") {
    ss = ""; for (i = 1; i <= nstf && i <= 5; i++) ss = ss (i > 1 ? ", " : "") STL[i]
    die("ERROR: " stale " piece(s) in " nstf " file(s) changed since the split (" ss (nstf > 5 ? ", ..." : "") "). The titles and descriptions were written for the old text. Re-run split (and the agents) on the current files, or pass --allow-stale to build anyway.")
  }
  outp = resolvep(ENVIRON["WB_OUTARG"] == "" ? "whitebox.json" : ENVIRON["WB_OUTARG"])
  if (system("test -d " shq(dirnamep(outp))) != 0) die("Error: ENOENT: no such file or directory, open '" outp "'")
  printf "{\"version\":1,\"root\":%s,\"title\":%s,\"tree\":", jstr(PROOT), jstr(title) > outp
  emitJson(root, outp)
  printf "}" > outp
  close(outp)
  for (i = 1; i <= TRN; i++) GOF[TR_path[i]] = TR_g[i]
  flat = outp; sub(/\.json$/, "", flat); flat = flat ".paths"
  flatn = 0; emitFlat(root, "", flat)
  if (flatn == 0) printf "\n" > flat
  close(flat)
  print "wrote " outp " (+ .paths): " NIDC " nodes, " dmsize() " descriptions"
}
