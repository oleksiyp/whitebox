#!/bin/sh
# whitebox validate (POSIX sh + awk port of validate.mjs): re-checks a whitebox.json against the source files.
#   validate.sh whitebox.json
LC_ALL=C
export LC_ALL
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
LIB=$HERE/lib
WB_CWD=$(pwd -P)
export WB_CWD
WB_FILE=${1:-whitebox.json}
export WB_FILE
exec awk -f "$LIB/bytes.awk" -f "$LIB/common.awk" -f "$LIB/json.awk" -f "$LIB/validate.awk" < /dev/null
