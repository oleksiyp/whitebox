# Shared awk helpers of the whitebox shell port (POSIX awk only; run under LC_ALL=C so every string is bytes).
# Loaded together with bytes.awk by every awk program of the port.

function initcommon(   i, h) {
  initbytes()
  for (i = 1; i < 128; i++) ORD[sprintf("%c", i)] = i
  for (i = 128; i < 256; i++) ORD[BY[i]] = i
  for (i = 128; i < 256; i++) CHR[i] = BY[i]
  for (i = 1; i < 128; i++) CHR[i] = sprintf("%c", i)
  h = "0123456789abcdef"
  for (i = 0; i < 16; i++) HEXV[substr(h, i + 1, 1)] = i
  for (i = 0; i < 16; i++) HEXV[toupper(substr(h, i + 1, 1))] = i
  # JSON escaping table
  for (i = 1; i < 32; i++) ESC[CHR[i]] = sprintf("\\u%04x", i)
  ESC["\""] = "\\\""; ESC["\\"] = "\\\\"; ESC["\b"] = "\\b"; ESC["\f"] = "\\f"; ESC["\n"] = "\\n"; ESC["\r"] = "\\r"; ESC["\t"] = "\\t"
  JRE = "[\"\\\\" CHR[1] "-" CHR[31] "]"
  CWD = ENVIRON["WB_CWD"]
}

# ---------- strings ----------
function trim(s) { sub(/^[ \t\r\n\f\013]+/, "", s); sub(/[ \t\r\n\f\013]+$/, "", s); return s }
function lower(s) { return tolower(s) }
# number of ASCII-whitespace separated words (the reference's W)
function W(s,   n, a, c) {
  if (s == "") return 0
  n = split(s, a, /[ \t\r\n\f\013]+/)
  c = n
  if (a[1] == "") c--
  if (n > 1 && a[n] == "") c--
  return c
}
function isblank(s) { return s ~ /^[ \t\r\n\f\013]*$/ }
function repeat(s, n,   r) { r = ""; while (n-- > 0) r = r s; return r }
function padstart(s, n) { s = "" s; while (length(s) < n) s = " " s; return s }
function shq(s,   r, i) {
  r = ""
  while ((i = index(s, "'")) > 0) { r = r substr(s, 1, i - 1) "'\\''"; s = substr(s, i + 1) }
  return "'" r s "'"
}
function startswith(s, p) { return substr(s, 1, length(p)) == p }

# ---------- JSON text ----------
# escape the inside of a JSON string exactly like JSON.stringify (no lone-surrogate handling)
function jesc(s,   out) {
  if (s !~ JRE) return s
  out = ""
  while (match(s, JRE)) { out = out substr(s, 1, RSTART - 1) ESC[substr(s, RSTART, 1)]; s = substr(s, RSTART + 1) }
  return out s
}
function jstr(s) { return "\"" jesc(s) "\"" }
function utf8(cp) {
  if (cp < 128) return cp == 0 ? "" : CHR[cp]
  if (cp < 2048) return CHR[192 + int(cp / 64)] CHR[128 + cp % 64]
  if (cp < 65536) return CHR[224 + int(cp / 4096)] CHR[128 + int(cp / 64) % 64] CHR[128 + cp % 64]
  return CHR[240 + int(cp / 262144)] CHR[128 + int(cp / 4096) % 64] CHR[128 + int(cp / 64) % 64] CHR[128 + cp % 64]
}
function hex4(h,   v, i) { v = 0; for (i = 1; i <= 4; i++) v = v * 16 + HEXV[substr(h, i, 1)]; return v }
# decode the inside of a JSON string (escapes) into raw bytes
function junesc(s,   out, i, c, cp, lo) {
  if (index(s, "\\") == 0) return s
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1); c = substr(s, i + 1, 1)
    if (c == "n") { out = out "\n"; s = substr(s, i + 2) }
    else if (c == "t") { out = out "\t"; s = substr(s, i + 2) }
    else if (c == "r") { out = out "\r"; s = substr(s, i + 2) }
    else if (c == "b") { out = out "\b"; s = substr(s, i + 2) }
    else if (c == "f") { out = out "\f"; s = substr(s, i + 2) }
    else if (c == "u") {
      cp = hex4(substr(s, i + 2, 4)); s = substr(s, i + 6)
      if (cp >= 55296 && cp < 56320 && substr(s, 1, 2) == "\\u") {
        lo = hex4(substr(s, 3, 4))
        if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); s = substr(s, 7) }
      }
      out = out utf8(cp)
    }
    else { out = out c; s = substr(s, i + 2) }   # \" \\ \/
  }
  return out s
}

# ---------- UTF-16 aware slice(0, n) of a UTF-8 byte string (the reference slices UTF-16 code units) ----------
function ucut(s, n,   i, len, c, o, u, out) {
  len = length(s)
  if (len <= n) return s
  u = 0
  for (i = 1; i <= len; i++) {
    c = substr(s, i, 1); o = ORD[c]
    if (o < 128 || o >= 192) { u += (o >= 240 ? 2 : 1); if (u > n) return substr(s, 1, i - 1) }
  }
  return s
}

# ---------- files ----------
# whole file as one string (the byte-exact content); SL_OK is 0 when the file cannot be read
function slurp(f,   rs, r, t, n, rec) {
  rs = RS; RS = "\001"; t = ""; n = 0; SL_OK = 1
  while ((r = (getline rec < f)) > 0) { t = (n++ ? t "\001" : "") rec; }
  if (r < 0 && n == 0) SL_OK = 0
  close(f); RS = rs
  return t
}
# JS: raw.replace(/\r\n/g, "\n").split("\n") into A[1..n]; returns n
function jsplit(raw, A,   n, i) {
  delete A; JS_CR = 0
  n = split(raw, A, "\n")
  if (n == 0) { A[1] = ""; return 1 }
  for (i = 1; i < n; i++) if (substr(A[i], length(A[i])) == "\r") { A[i] = substr(A[i], 1, length(A[i]) - 1); JS_CR = 1 }
  return n
}
function fileexists(f,   r, x) { r = (getline x < f); if (r >= 0) { close(f); return 1 } return 0 }

# ---------- paths ----------
function normpath(p,   n, a, i, out, m, st) {
  n = split(p, a, "/"); m = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (m > 0) m--; continue }
    st[++m] = a[i]
  }
  out = ""
  for (i = 1; i <= m; i++) out = out "/" st[i]
  return out == "" ? "/" : out
}
function resolvep(p) { return normpath(substr(p, 1, 1) == "/" ? p : CWD "/" p) }
function dirnamep(p,   i) { i = length(p); while (i > 1 && substr(p, i, 1) != "/") i--; return i <= 1 ? (substr(p, 1, 1) == "/" ? "/" : ".") : substr(p, 1, i - 1) }
function basenamep(p,   i) { i = length(p); while (i > 0 && substr(p, i, 1) != "/") i--; return substr(p, i + 1) }
# path.relative(from, to) for absolute normalised paths
function relativep(from, to,   a, b, na, nb, i, k, out) {
  if (from == to) return ""
  na = split(from == "/" ? "" : substr(from, 2), a, "/"); nb = split(to == "/" ? "" : substr(to, 2), b, "/")
  k = 0
  while (k < na && k < nb && a[k + 1] == b[k + 1]) k++
  out = ""
  for (i = k + 1; i <= na; i++) out = out (out == "" ? "" : "/") ".."
  for (i = k + 1; i <= nb; i++) out = out (out == "" ? "" : "/") b[i]
  return out
}
# arguments printed for agents are quoted when they contain special characters (reference: q())
function q(x,   i, c, sp) {
  sp = " \t\"'\\$&;()<>|*?[]{}!~#`"
  for (i = 1; i <= length(sp); i++) if (index(x, substr(sp, i, 1)) > 0) return jstr(x)
  return x
}

# ---------- numbers ----------
function jsnum(x) { return (x == int(x)) ? sprintf("%d", x) : x "" }
function round(x) { return int(x + 0.5) }
