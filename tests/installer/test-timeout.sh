#!/bin/sh
# Child timeout self-test: sleep 30 with a 1 second limit.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$test_dir/../initrd/lib.sh"

test_out=
test_status=0
if test_out=$("${KEEL_INSTALL_BIN}" --self-test-timeout 1 2>&1); then
    test_status=0
else
    test_status=$?
fi
echo "$test_out"
assert_status 0 "$test_status" "self-test status"
assert_contains "$test_out" "self-test-timeout: rc=124" "self-test timeout rc"

sleep 0.2
leftover=$(ps -eo pid=,args= | awk '$2 == "sleep" && $3 == "30"')
assert_empty "$leftover" "no leftover sleep 30"

test_finish "test-timeout"
