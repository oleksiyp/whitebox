#!/bin/sh
# whitebox build-editor (POSIX sh + awk port of build-editor.mjs): self-contained editor page with the tree embedded.
#   build-editor.sh [whitebox.json] [out.html]
LC_ALL=C
export LC_ALL
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
LIB=$HERE/lib
WB_CWD=$(pwd -P)
export WB_CWD
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/wbsh.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 1' HUP INT TERM
WB_SRC=${1:-whitebox.json}
OUT=${2:-whitebox.html}
WB_OUT=$TMPD/out.html
WB_TEMPLATE=$HERE/editor.template.html
WB_APPLYCMD="sh $(HERE=$HERE awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/relpath.awk" < /dev/null)"
export WB_SRC WB_OUT WB_TEMPLATE WB_APPLYCMD
awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/json.awk" -f "$LIB/buildeditor.awk" < /dev/null || exit 1
cp "$WB_OUT" "$OUT" || exit 1
echo "wrote $OUT"
