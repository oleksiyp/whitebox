#!/bin/sh
# Test helper: run a command inside the long-lived wb-pwsh container (docker run -d --name wbps -v /tmp:/tmp -v "$REPO:$REPO" wb-pwsh sleep infinity),
# in the caller's working directory, and retry when the emulator (qemu, arm32 image on an arm64 host) kills the process: that is the
# runtime crashing (exit 134/139 and a "qemu:" / "Assertion failed" line), never an answer of the port. Use as
#   WHITEBOX_PREFIX=$PWD/test/docker/pwsh-exec.sh WHITEBOX_IMPL=ps WHITEBOX_PWSH=pwsh npm test
C=${WB_PS_CONTAINER:-wbps}
n=0
while [ $n -lt 25 ]; do
  n=$((n + 1))
  out=$(mktemp); err=$(mktemp)
  docker exec -i -w "$PWD" "$C" "$@" >"$out" 2>"$err" </dev/null; rc=$?
  if [ $rc -ne 134 ] && [ $rc -ne 139 ] && [ $rc -ne 132 ]; then cat "$out"; cat "$err" >&2; rm -f "$out" "$err"; exit $rc; fi
  if ! grep -q 'qemu:\|Assertion failed\|Fatal error' "$err"; then cat "$out"; cat "$err" >&2; rm -f "$out" "$err"; exit $rc; fi
  rm -f "$out" "$err"
  sleep 1
done
echo "pwsh-exec.sh: emulator crashed $n times" >&2
exit 99
