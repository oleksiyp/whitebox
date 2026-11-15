#!/bin/sh
# whitebox apply-edits (POSIX sh + awk port of apply-edits.mjs): write edits made in the whitebox editor back to the markdown files.
#   apply-edits.sh edits.json [--root DIR] [--drop-excluded] [--dry-run]
# Every change is verified: the lines on disk must still equal the leaf's original text, otherwise that file is
# left untouched and reported as a conflict.
LC_ALL=C
export LC_ALL
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
LIB=$HERE/lib
WB_CWD=$(pwd -P)
export WB_CWD
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/wbsh.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 1' HUP INT TERM
: > "$TMPD/args"
for a in "$@"; do printf '%s\n' "$a" >> "$TMPD/args"; done
WB_ARGFILE=$TMPD/args
export WB_ARGFILE
awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/json.awk" -f "$LIB/applyedits.awk" < /dev/null
