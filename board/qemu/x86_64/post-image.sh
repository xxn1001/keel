#!/bin/sh
# Build the P0 initramfs and recovery images after Buildroot rootfs output.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
"${repo_dir}/tools/mkinitrd.sh"
"${repo_dir}/tools/mkrecovery.sh"
