#!/bin/sh
# Run installer tests that need no root, loop devices, or QEMU.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$test_dir/../.." && pwd)
test_tmp="${TMPDIR:-/tmp}/keel-installer-tests.$$"
bin="${test_tmp}/keel-install"

mkdir -p "$test_tmp"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

${CC:-cc} -std=c99 -Wall -Wextra -Werror -o "$bin" \
    "$repo_dir/src/installer/main.c" \
    "$repo_dir/src/installer/run.c"

KEEL_INSTALL_BIN="$bin" sh "$test_dir/test-dry-run.sh"
echo "tests/installer: ok"
