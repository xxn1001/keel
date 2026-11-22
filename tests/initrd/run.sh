#!/bin/sh
# Run initrd tests that need no root, loop devices, or QEMU.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
status=0
for test in test-cmdline.sh test-discover.sh; do
    echo "== $test"
    sh "$test_dir/$test" || status=1
done
[ "$status" -eq 0 ] || { echo "tests/initrd: failed"; exit 1; }
echo "tests/initrd: ok"
