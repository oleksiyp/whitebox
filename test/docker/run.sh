#!/bin/sh
# Run a command inside one of the wb-* images with the caller's working directory and the repo mounted at the same paths.
#   one container per call:   WHITEBOX_PREFIX="sh $PWD/test/docker/run.sh wb-debian" TMPDIR=/tmp WHITEBOX_IMPL=sh WHITEBOX_SH=dash npm test
#   one long-lived container (much faster): docker run -d --name wbc -v /private/tmp:/private/tmp -v /private/tmp:/tmp -v $PWD:$PWD wb-debian sleep 100000
#                             WHITEBOX_PREFIX="sh $PWD/test/docker/run.sh --exec wbc" ...
# The host temp directory is mounted at its real path and at /tmp (macOS: /tmp is /private/tmp; run the tests with TMPDIR=/tmp there).
here=$(cd "$(dirname "$0")/../.." && pwd -P)
cwd=$(pwd -P)
if [ "$1" = "--exec" ]; then
  c=$2; shift 2
  exec docker exec -i -w "$cwd" "$c" "$@"
fi
img=$1; shift
t=$(cd /tmp && pwd -P)
if [ "$t" = /tmp ]; then mounts="-v /tmp:/tmp"; else mounts="-v $t:$t -v $t:/tmp"; fi
# shellcheck disable=SC2086
exec docker run --rm -i $mounts -v "$here:$here" -w "$cwd" "$img" "$@"
