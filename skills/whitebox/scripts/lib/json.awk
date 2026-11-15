# Minimal JSON reader for the whitebox shell port. jload(file) flattens a JSON document into
#   J[path] (scalar value, strings decoded)   JT[path] ("s" "n" "b" "z" "o" "a")   JN[path] (child count)   JK[path, i] (object key i, 1-based)
# where a child path is parent "\001" key (array indexes are 0-based). The root path is "$".
# The file is read with RS="," so that no awk string ever grows beyond a record: some awks (BWK) take time proportional
# to the whole string on every substr(), which would make a 10 MB single-line whitebox.json quadratic.
# jstream(file) calls jemit(type, text) for every token; type is one of { } [ ] : , s (raw, still escaped, string body) n b z.

function jp(parent, key) { return parent "\001" key }

function jload(f,   r) {
  delete J; delete JT; delete JN; delete JK
  JD = 0; JMODE = "dom"
  return jstream(f)
}
function jemit(t, v) {
  if (JMODE == "min") minemit(t, v)
  else domemit(t, v)
}
function jchild(t,   par, key, p) {
  if (JD == 0) { p = "$" }
  else if (JST[JD] == "o") { par = SP[JD]; key = JKEY[JD]; p = jp(par, key); JN[par]++; JK[par, JN[par]] = key }
  else { par = SP[JD]; p = jp(par, JN[par]); JN[par]++ }
  JT[p] = t
  return p
}
function domemit(t, v,   p) {
  if (t == "{" || t == "[") {
    p = jchild(t == "{" ? "o" : "a"); JN[p] = 0
    JD++; SP[JD] = p; JST[JD] = (t == "{" ? "o" : "a"); JW[JD] = (t == "{")
  } else if (t == "}" || t == "]") JD--
  else if (t == ",") { if (JD > 0 && JST[JD] == "o") JW[JD] = 1 }
  else if (t == ":") { }
  else if (t == "s") {
    if (JD > 0 && JST[JD] == "o" && JW[JD]) { JKEY[JD] = junesc(v); JW[JD] = 0 }
    else { p = jchild("s"); J[p] = junesc(v) }
  } else { p = jchild(t); J[p] = v }
}

# closing quote of the string whose body starts at s[from]; 0 when it is not in s
function findq(s, from,   p, i, qq, b, k) {
  p = from
  while (1) {
    i = index(substr(s, p), "\"")
    if (i == 0) return 0
    qq = p + i - 1; b = 0; k = qq - 1
    while (k >= from && substr(s, k, 1) == "\\") { b++; k-- }
    if (b % 2 == 0) return qq
    p = qq + 1
  }
}
function jstream(f,   rs, r, rec, first, instr, jstr_, pos, len, c, qq, chunk, ok) {
  rs = RS; RS = ","; first = 1; instr = 0; jstr_ = ""; ok = 1
  while ((r = (getline rec < f)) > 0) {
    if (first) first = 0
    else if (instr) jstr_ = jstr_ ","
    else jemit(",", ",")
    pos = 1; len = length(rec)
    if (instr) {
      qq = findq(rec, 1)
      if (qq) { jemit("s", jstr_ substr(rec, 1, qq - 1)); instr = 0; jstr_ = ""; pos = qq + 1 }
      else { jstr_ = jstr_ rec; pos = len + 1 }
    }
    while (pos <= len) {
      c = substr(rec, pos, 1)
      if (c == " " || c == "\t" || c == "\r" || c == "\n") { pos++; continue }
      if (c == "\"") {
        qq = findq(rec, pos + 1)
        if (qq) { jemit("s", substr(rec, pos + 1, qq - pos - 1)); pos = qq + 1 }
        else { instr = 1; jstr_ = substr(rec, pos + 1); pos = len + 1 }
      } else if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":") { jemit(c, c); pos++ }
      else {
        chunk = substr(rec, pos, 48)
        if (match(chunk, /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) { jemit("n", substr(chunk, 1, RLENGTH)); pos += RLENGTH }
        else if (substr(chunk, 1, 4) == "true") { jemit("b", "true"); pos += 4 }
        else if (substr(chunk, 1, 5) == "false") { jemit("b", "false"); pos += 5 }
        else if (substr(chunk, 1, 4) == "null") { jemit("z", "null"); pos += 4 }
        else pos++
      }
    }
  }
  if (r < 0 && first) ok = 0
  close(f); RS = rs
  return ok
}

# string starting at line[pos] == '"' (used on short single-line records): raw inner text in JSV, returns the position after the closing quote
function jstring(line, pos, len,   qq) {
  qq = findq(line, pos + 1)
  if (qq) { JSV = substr(line, pos + 1, qq - pos - 1); return qq + 1 }
  JSV = substr(line, pos + 1); return len + 1
}

# JS Number(str): returns 1 and sets NUMV when the string is a finite number, else 0 (NaN)
function jsnumber(s) {
  s = trim(s)
  if (s == "") { NUMV = 0; return 1 }
  if (s ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) { NUMV = s + 0; return 1 }
  if (s ~ /^0[xX][0-9a-fA-F]+$/) { NUMV = hexnum(substr(s, 3)); return 1 }
  return 0
}
function hexnum(h,   v, i) { v = 0; for (i = 1; i <= length(h); i++) v = v * 16 + HEXV[substr(h, i, 1)]; return v }
# JS String(Number(str)) for the values the checkers print
function numstr(s) { if (!jsnumber(s)) return "NaN"; return jsnum(NUMV) }
function isint(x) { return x == int(x) }

# ---- compact re-serialisation (build-editor): tokens are written to the file JOUT, "<" escaped like the reference ----
function lt(s,   o, i) {
  if (index(s, "<") == 0) return s
  o = ""
  while ((i = index(s, "<")) > 0) { o = o substr(s, 1, i - 1) "\\u003c"; s = substr(s, i + 1) }
  return o s
}
function minemit(t, v) {
  if (t == "s") {
    if (index(v, "\\") == 0) printf "\"%s\"", lt(v) > JOUT
    else printf "\"%s\"", lt(jesc(junesc(v))) > JOUT
  } else if (t == "n") printf "%s", (v == "-0" ? "0" : v) > JOUT
  else printf "%s", v > JOUT
}
