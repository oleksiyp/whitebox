#!/bin/sh
# whitebox build-editor (POSIX sh + awk port of build-editor.mjs): self-contained editor page with the tree embedded.
#   build-editor.sh <whitebox.json> <out.html> [--title NAME] [--artifact]
LC_ALL=C
export LC_ALL
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
LIB=$HERE/lib
WB_CWD=$(pwd -P)
export WB_CWD
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/wbsh.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 1' HUP INT TERM
WB_SRC=; OUT=; WB_TITLE=; WB_HASTITLE=0; WB_ARTIFACT=0; n=0
while [ $# -gt 0 ]; do
  case $1 in
    --artifact) WB_ARTIFACT=1 ;;
    --title) WB_HASTITLE=1; shift; WB_TITLE=${1-} ;;
    --*) ;;
    *) n=$((n + 1)); if [ $n -eq 1 ]; then WB_SRC=$1; elif [ $n -eq 2 ]; then OUT=$1; fi ;;
  esac
  [ $# -gt 0 ] && shift
done
if [ $n -lt 2 ]; then echo 'usage: build-editor <whitebox.json> <out.html> [--title "Name"] [--artifact]' >&2; exit 2; fi
WB_OUT=$TMPD/out.html
WB_TEMPLATE=$HERE/editor.template.html
WB_APPLYCMD="sh $(HERE=$HERE awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/relpath.awk" < /dev/null)"
export WB_SRC WB_OUT WB_TEMPLATE WB_APPLYCMD WB_TITLE WB_HASTITLE WB_ARTIFACT
awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/json.awk" -f "$LIB/buildeditor.awk" < /dev/null || exit 1
cp "$WB_OUT" "$OUT" || exit 1
echo "wrote $OUT"
