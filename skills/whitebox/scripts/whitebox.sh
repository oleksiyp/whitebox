#!/bin/sh
# whitebox (POSIX sh + awk port of whitebox.mjs): turn a project (markdown + source code) into one overseeable, editable tree.
# See docs/porting.md. The deterministic work happens in awk programs under lib/; this file parses arguments,
# lists files (git or a directory walk) and starts the right program.
LC_ALL=C
export LC_ALL

SELF_ARG=$0
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
LIB=$HERE/lib
WB_CWD=$(pwd -P)
export WB_CWD

die() { printf '%s\n' "$1" >&2; exit 1; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/wbsh.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 1' HUP INT TERM
WB_TMP=$TMPD
export WB_TMP

cmd=$1
[ $# -gt 0 ] && shift

# ---- argument parsing (same rules as the reference) ----
# opt NAME DEFAULT: value after the first occurrence of NAME
opt() {
  _n=$1; _d=$2; _take=0
  for _a in "$@"; do :; done
  shift 2
  for _a in "$@"; do
    if [ $_take = 1 ]; then printf '%s' "$_a"; return; fi
    if [ "$_a" = "$_n" ]; then _take=1; fi
  done
  if [ $_take = 1 ]; then return; fi
  printf '%s' "$_d"
}
has() {
  _n=$1; shift
  for _a in "$@"; do [ "$_a" = "$_n" ] && return 0; done
  return 1
}
# positional arguments, one per line, into $TMPD/pos (not starting with -- and not the value of a value flag)
positionals() {
  : > "$TMPD/pos"
  _prev=$cmd
  for _a in "$@"; do
    case $_a in
      --*) ;;
      *) case $_prev in --work|--out|--window|--groups|--max-kb|--include|--exclude) ;; *) printf '%s\n' "$_a" >> "$TMPD/pos" ;; esac ;;
    esac
    _prev=$_a
  done
}
pos() { sed -n "${1}p" "$TMPD/pos"; }
npos() { wc -l < "$TMPD/pos" | tr -d ' '; }

abspath() {
  WB_X=$1 run_awk abspath.awk </dev/null
}

sha_cmd() {
  if command -v sha1sum >/dev/null 2>&1; then echo "sha1sum"
  elif command -v shasum >/dev/null 2>&1; then echo "shasum -a 1"
  elif command -v openssl >/dev/null 2>&1; then echo "openssl sha1"
  else die "no sha1 tool found (sha1sum, shasum or openssl)"; fi
}

run_awk() { # run_awk PROGRAM... (files of lib/, environment already prepared)
  _n=$#
  while [ "$_n" -gt 0 ]; do set -- "$@" -f "$LIB/$1"; shift; _n=$((_n - 1)); done
  awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" "$@"
}

WORKARG=$(opt --work .whitebox "$@")
WORK=$(abspath "$WORKARG")
positionals "$@"

# ---- split ----
cmd_split() {
  [ "$(npos)" -gt 0 ] || die "usage: split <dir|file...> --work W [--tests] [--config] [--max-kb 300] [--include globs] [--exclude globs]"
  first=$(pos 1)
  if [ "$(npos)" = 1 ]; then
    [ -e "$first" ] || die "Error: ENOENT: no such file or directory, stat '$first'"
  fi
  if [ "$(npos)" = 1 ] && [ -d "$first" ]; then
    ROOT=$(abspath "$first")
    if git -c safe.directory='*' -C "$ROOT" ls-files -co --exclude-standard -z > "$TMPD/git.z" 2>/dev/null; then
      mode=git
      tr '\0' '\n' < "$TMPD/git.z" | sed '/^$/d' > "$TMPD/rels"
    else
      mode=walk
      (cd "$ROOT" && find . \( -name '.?*' -o -name node_modules \) -prune -o \( -type f -o -type l \) -print) | sed 's|^\./||' | sort > "$TMPD/rels"
    fi
    total=$(wc -l < "$TMPD/rels" | tr -d ' ')
    while IFS= read -r rel; do
      [ -f "$ROOT/$rel" ] && printf '%s\n' "$rel"
    done < "$TMPD/rels" > "$TMPD/list"
  else
    mode=files; ROOT=; total=0
    : > "$TMPD/list"
    i=1; n=$(npos)
    while [ "$i" -le "$n" ]; do
      f=$(pos "$i")
      [ -f "$f" ] || die "Error: ENOENT: no such file or directory, open '$f'"
      abspath "$f" >> "$TMPD/list"
      i=$((i + 1))
    done
  fi
  mkdir -p "$WORK/out" "$WORK/desc" || exit 1
  WB_MODE=$mode WB_LIST=$TMPD/list WB_TOTAL=$total WB_ROOT=$ROOT WB_WORK=$WORK WB_WIN=$(opt --window 220 "$@") \
  WB_MAXKB=$(opt --max-kb 300 "$@") WB_INCL=$(opt --include "" "$@") WB_EXCL=$(opt --exclude "" "$@") \
  WB_TESTS=$(has --tests "$@" && echo 1) WB_CFG=$(has --config "$@" && echo 1) WB_SHA=$(sha_cmd) \
  run_awk split.awk </dev/null
}

# ---- every other subcommand lives in lib/wb.awk ----
cmd_wb() {
  if [ "$cmd" = reshape-list ]; then
    [ -f "$WORK/tree.paths" ] || die "run apply-merge first"
    if [ -d "$WORK/reshape" ] && [ -n "$(ls -A "$WORK/reshape")" ]; then mv "$WORK/reshape" "$WORK/reshape-archive-$(date +%s)000"; fi
    mkdir -p "$WORK/reshape"
  fi
  WB_CMD=$cmd WB_WORKARG=$WORKARG WB_SELF=$SELF_ARG WB_POSFILE=$TMPD/pos WB_TPL=$LIB/tpl \
  WB_FORCE=$(has --force "$@" && echo 1) WB_ALLOWSTALE=$(has --allow-stale "$@" && echo 1) WB_OUTARG=$(opt --out "" "$@") \
  WB_SHA=$(sha_cmd) \
  run_awk json.awk wb.awk </dev/null
}

case $cmd in
  split) cmd_split "$@" ;;
  window|check|check-all|status|merge-input|apply-merge|describe-input|check-desc|reshape-list|reshape-count|reshape-input|check-reshape|apply-reshape|groups-args|estimate|build) cmd_wb "$@" ;;
  *) die "unknown command ${cmd:-undefined}" ;;
esac
