#!/bin/sh
# Test the UKI command line text.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$test_dir/../.." && pwd)
# shellcheck source=/dev/null
. "$test_dir/../initrd/lib.sh"
# shellcheck source=/dev/null
. "$repo_dir/tools/mkuki.sh"

assert_eq \
    "root=/dev/system/root_a ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1" \
    "$(uki_cmdline /dev/system/root_a)" \
    "cmdline A"

assert_eq \
    "root=/dev/system/root_b ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1" \
    "$(uki_cmdline /dev/system/root_b)" \
    "cmdline B"

test_finish "test-mkuki"
