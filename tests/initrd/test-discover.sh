#!/bin/sh
# Partition discovery tests against fake sysfs and /dev trees.
set -eu
test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixtures="$test_dir/fixtures"
# shellcheck source=/dev/null
. "$test_dir/lib.sh"
# shellcheck source=/dev/null
. "$test_dir/../../board/common/initrd/lib/discover.sh"
test_tmp="${TMPDIR:-/tmp}/keel-test-discover.$$"
mkdir -p "$test_tmp"
trap 'rm -rf "$test_tmp" "$fixtures"/*/dev/disk' EXIT HUP INT TERM
test_status=0
test_out=
discover_case() {
    _discover_case=$1
    KEEL_SYSFS="$fixtures/$_discover_case/sys"
    KEEL_DEV="$fixtures/$_discover_case/dev"
    test_status=0
    test_out=
    if keel_discover >"$test_tmp/output" 2>&1; then
        test_status=0
    else
        test_status=$?
    fi
    test_out=$(cat "$test_tmp/output")
}
install_links_case() {
    _links_case=$1
    KEEL_SYSFS="$fixtures/$_links_case/sys"
    KEEL_DEV="$fixtures/$_links_case/dev"
    export KEEL_SYSFS KEEL_DEV
    keel_install_links
}
discover_case single-vda
assert_status 0 "$test_status" "single vda status"
assert_contains "$test_out" \
    "disk=vda system=vda3 recovery=vda2 data=vda4 esp=vda1" \
    "single vda devices"
install_links_case single-vda
_linkdir="$fixtures/single-vda/dev/disk/by-partlabel"
assert_link_target "$_linkdir/system" "../../vda3" "vda system link"
assert_link_target "$_linkdir/recovery" "../../vda2" "vda recovery link"
assert_link_target "$_linkdir/data" "../../vda4" "vda data link"
assert_link_target "$_linkdir/esp" "../../vda1" "vda esp link"
discover_case single-nvme
assert_status 0 "$test_status" "single nvme status"
assert_contains "$test_out" \
    "disk=nvme0n1 system=nvme0n1p3 recovery=nvme0n1p2 data=nvme0n1p4 esp=nvme0n1p1" \
    "single nvme devices"
install_links_case single-nvme
assert_link_target "$fixtures/single-nvme/dev/disk/by-partlabel/system" \
    "../../nvme0n1p3" "nvme system link"
discover_case two-system
assert_status 3 "$test_status" "two system status"
assert_contains "$test_out" "candidate system=vda3 disk=vda" "two system vda"
assert_contains "$test_out" "candidate system=vdb3 disk=vdb" "two system vdb"
assert_not_exists "$fixtures/two-system/dev/disk/by-partlabel" \
    "two system creates no links"
discover_case duplicate-data
assert_status 3 "$test_status" "duplicate data status"
assert_contains "$test_out" "candidate data=vda4" "duplicate data first"
assert_contains "$test_out" "candidate data=vda5" "duplicate data second"
assert_not_exists "$fixtures/duplicate-data/dev/disk/by-partlabel" \
    "duplicate data creates no links"
discover_case missing-data
assert_status 0 "$test_status" "missing data status"
assert_empty "$KEEL_DEV_DATA" "missing data stays empty"
assert_eq "vda3" "$KEEL_DEV_SYSTEM" "missing data system"
install_links_case missing-data
assert_link_target "$fixtures/missing-data/dev/disk/by-partlabel/system" \
    "../../vda3" "missing data system link"
assert_not_exists "$fixtures/missing-data/dev/disk/by-partlabel/data" \
    "missing data has no data link"
saved_path=$PATH
PATH="$fixtures/no-partname-blkid/bin:$PATH"
discover_case no-partname-blkid
PATH=$saved_path
assert_status 0 "$test_status" "blkid fallback status"
assert_contains "$test_out" \
    "disk=vda system=vda3 recovery=vda2 data=vda4 esp=vda1" \
    "blkid fallback devices"
install_links_case no-partname-blkid
_linkdir="$fixtures/no-partname-blkid/dev/disk/by-partlabel"
assert_link_target "$_linkdir/system" "../../vda3" "blkid system link"
test_finish test-discover
