#!/bin/sh
# Run a command inside one of the wb-* images with the caller's working directory and the repo mounted at the same paths.
#   one container per call:   WHITEBOX_PREFIX="sh $PWD/test/docker/run.sh wb-debian" TMPDIR=/tmp WHITEBOX_IMPL=sh WHITEBOX_SH=dash npm test
#   one long-lived container (much faster): docker run -d --name wbc -v /private/tmp:/private/tmp -v /private/tmp:/tmp -v $PWD:$PWD wb-debian sleep 100000
#                             WHITEBOX_PREFIX="sh $PWD/test/docker/run.sh --exec wbc" ...
# (macOS: /tmp is /private/tmp, which is why both paths are mounted; run the tests with TMPDIR=/tmp.)
here=$(cd "$(dirname "$0")/../.." && pwd -P)
cwd=$(pwd -P)
if [ "$1" = "--exec" ]; then
  c=$2; shift 2
  exec docker exec -i -w "$cwd" "$c" "$@"
fi
img=$1; shift
exec docker run --rm -i -v /private/tmp:/private/tmp -v /private/tmp:/tmp -v "$here:$here" -w "$cwd" "$img" "$@"
