#!/bin/sh
# Dry-run plan checks for keel-install.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$test_dir/../initrd/lib.sh"

test_tmp="${TMPDIR:-/tmp}/keel-test-installer.$$"
source_dir="${test_tmp}/source"
disk_64="${test_tmp}/disk64.raw"
disk_4="${test_tmp}/disk4.raw"
out_file="${test_tmp}/stdout"
err_file="${test_tmp}/stderr"
test_status=0
test_out=
test_err=

mkdir -p "$source_dir"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
for name in rootfs.erofs recovery.erofs keel-a.efi keel-b.efi; do
    : > "$source_dir/$name"
done
truncate -s 64G "$disk_64"
truncate -s 4G "$disk_4"

run_install() {
    test_status=0
    if "${KEEL_INSTALL_BIN}" "$@" >"$out_file" 2>"$err_file"; then
        test_status=0
    else
        test_status=$?
    fi
    test_out=$(cat "$out_file")
    test_err=$(cat "$err_file")
}

# Regular files are treated as 512-byte-sector devices by the dry-run path;
# this case also covers the logical-sector-size guard.
run_install --disk "$disk_64" --source "$source_dir" --dry-run
assert_status 0 "$test_status" "64 GiB dry-run status"
assert_contains "$test_out" \
    'start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"' \
    "esp partition"
assert_contains "$test_out" \
    'start=2099200, size=2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="recovery"' \
    "recovery partition"
assert_contains "$test_out" \
    'start=4196352, size=12582912, type=E6D6D379-F507-44C2-A23C-238F2A3DF928, name="system"' \
    "system partition"
assert_contains "$test_out" \
    'start=16779264, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="data"' \
    "data partition"
assert_contains "$test_out" \
    'gpt types: esp=EF00 recovery=8300 system=8E00 data=8300' \
    "partition type mapping"
assert_contains "$test_out" \
    'lvcreate --yes --name root_a --size 2G system' "root_a LV"
assert_contains "$test_out" \
    'lvcreate --yes --name root_b --size 2G system' "root_b LV"
assert_contains "$test_out" \
    'lvcreate --yes --name etc --size 1G system' "etc LV"
assert_contains "$test_out" "rootfs.erofs -> /dev/system/root_a" \
    "root_a image write"
assert_contains "$test_out" "rootfs.erofs -> /dev/system/root_b" \
    "root_b image write"
assert_contains "$test_out" "recovery.erofs -> /dev/disk/by-partlabel/recovery" \
    "recovery image write"
assert_contains "$test_out" "mkfs.btrfs -f -L data" "data mkfs"
assert_contains "$test_out" "btrfs subvolume create /mnt/data/var" "var subvolume"
assert_contains "$test_out" "btrfs subvolume create /mnt/data/home" "home subvolume"
assert_contains "$test_out" \
    'mkfs.vfat -F 32 -n KEELESP /dev/disk/by-partlabel/esp' "ESP mkfs"
assert_contains "$test_out" "keel-a.efi /mnt/esp/EFI/Linux/keel-a+10.efi" \
    "ESP keel-a copy"
assert_contains "$test_out" "default keel-a*" "ESP loader default"
assert_contains "$test_out" "bootctl --esp-path=/mnt/esp install" \
    "ESP bootctl install"
assert_contains "$test_out" "partitions=esp,recovery,system,data" "summary partitions"
assert_contains "$test_out" "lvs=root_a,root_b,etc" "summary LVs"

# A regular file must stay on the 512-byte path; the 4Kn guard only applies
# to real block devices.
run_install --disk "$disk_64" --source "$source_dir" --dry-run
assert_status 0 "$test_status" "regular-file sector size"

run_install --disk "$disk_4" --source "$source_dir" --dry-run
assert_status 3 "$test_status" "4 GiB disk status"
assert_contains "$test_err" "disk too small" "4 GiB message"

mv "$source_dir/keel-b.efi" "$source_dir/keel-b.missing"
run_install --disk "$disk_64" --source "$source_dir" --dry-run
assert_status 2 "$test_status" "missing source status"
assert_contains "$test_err" "keel-b.efi" "missing source name"
mv "$source_dir/keel-b.missing" "$source_dir/keel-b.efi"

run_install --source "$source_dir" --dry-run
assert_status 2 "$test_status" "missing disk status"
assert_contains "$test_err" "usage: keel-install" "missing disk usage"

run_install --disk "$disk_64" --source "$source_dir" --dry-run --bogus
assert_status 2 "$test_status" "unknown argument status"

run_install --disk "$disk_64" --source "$source_dir" --dry-run --timeout abc
assert_status 2 "$test_status" "bad timeout status"
assert_contains "$test_err" "invalid timeout" "bad timeout message"

run_install --disk "$disk_64" --source "$source_dir" --dry-run --timeout 0
assert_status 2 "$test_status" "zero timeout status"

test_finish "test-dry-run"
