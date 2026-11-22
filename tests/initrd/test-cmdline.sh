#!/bin/sh
# Cmdline parsing and validation tests.
set -eu
test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$test_dir/lib.sh"
# shellcheck source=/dev/null
. "$test_dir/../../board/common/initrd/lib/cmdline.sh"
test_tmp="${TMPDIR:-/tmp}/keel-test-cmdline.$$"
mkdir -p "$test_tmp"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
test_status=0
test_err=
parse_case() {
    test_status=0
    test_err=
    if keel_parse_cmdline "$1" >/dev/null 2>"$test_tmp/stderr"; then
        test_status=0
    else
        test_status=$?
    fi
    test_err=$(cat "$test_tmp/stderr")
}
parse_case "root=/dev/system/root_a ro rootfstype=erofs panic=-1 console=ttyS0"
assert_status 0 "$test_status" "normal cmdline status"
assert_empty "$test_err" "normal cmdline warnings"
assert_eq "/dev/system/root_a" "$KEEL_ROOT" "normal root"
assert_eq "0" "$KEEL_RECOVERY" "normal recovery flag"
assert_empty "$KEEL_FAIL" "normal fail flag"
assert_eq "30" "$KEEL_T_LVM" "normal lvm timeout"
parse_case "root=/dev/system/root_b keel.xxx=1"
assert_status 0 "$test_status" "unknown key status"
assert_contains "$test_err" "keel: warn: unknown parameter keel.xxx, ignored" \
    "unknown key warning"
assert_eq "/dev/system/root_b" "$KEEL_ROOT" "unknown key root"
parse_case "root=/dev/system/root_a keel.fail=bogus"
assert_contains "$test_err" "invalid keel.fail=bogus" "unknown fail warning"
assert_empty "$KEEL_FAIL" "unknown fail is ignored"
parse_case "root=/dev/system/root_a keel.timeout=root:abc"
assert_status 0 "$test_status" "bad timeout status"
assert_contains "$test_err" "invalid keel.timeout=root:abc" "bad timeout warning"
assert_eq "15" "$KEEL_T_ROOT" "bad timeout keeps default"
parse_case "root=/dev/system/root_a keel.timeout=foo:30"
assert_status 0 "$test_status" "unknown timeout status"
assert_contains "$test_err" "unknown timeout name: foo" "unknown timeout warning"
assert_eq "30" "$KEEL_T_LVM" "unknown timeout keeps lvm default"
parse_case "root=/dev/system/root_a keel.timeout=root:0"
assert_status 0 "$test_status" "low timeout status"
assert_contains "$test_err" "clamped to 1" "low timeout warning"
assert_eq "1" "$KEEL_T_ROOT" "low timeout clamps to 1"
parse_case "root=/dev/system/root_a keel.timeout=root:99999"
assert_status 0 "$test_status" "high timeout status"
assert_contains "$test_err" "clamped to 600" "high timeout warning"
assert_eq "600" "$KEEL_T_ROOT" "high timeout clamps to 600"
parse_case "root=/dev/system/root_a keel.timeout=lvm:45 keel.timeout=esp:5"
assert_status 0 "$test_status" "timeout overrides status"
assert_empty "$test_err" "timeout overrides warning"
assert_eq "45" "$KEEL_T_LVM" "lvm timeout override"
assert_eq "5" "$KEEL_T_ESP" "esp timeout override"
parse_case "root=/dev/system/root_a keel.timeout=root:10 keel.timeout=root:20"
assert_status 0 "$test_status" "duplicate timeout status"
assert_contains "$test_err" "duplicate keel.timeout=root" "duplicate timeout warning"
assert_eq "20" "$KEEL_T_ROOT" "duplicate timeout last wins"
parse_case "root=/dev/system/root_a keel.recovery=1"
assert_status 0 "$test_status" "recovery status"
assert_empty "$test_err" "recovery warning"
assert_eq "1" "$KEEL_RECOVERY" "recovery enabled"
parse_case "root=/dev/system/root_a keel.recovery=true"
assert_status 0 "$test_status" "bad recovery status"
assert_contains "$test_err" "invalid keel.recovery=true" "bad recovery warning"
assert_eq "0" "$KEEL_RECOVERY" "bad recovery is ignored"
parse_case "root=/dev/system/root_a keel.mode=install"
assert_status 0 "$test_status" "install mode status"
assert_empty "$test_err" "install mode is passed through without warning"
parse_case "root=/dev/system/root_x ro"
assert_status 2 "$test_status" "invalid root status"
assert_contains "$test_err" "keel: error: invalid root=/dev/system/root_x" \
    "invalid root error"
assert_eq "/dev/system/root_x" "$KEEL_ROOT" "invalid root is preserved"
parse_case "root=/dev/system/root_a root=/dev/system/root_b"
assert_status 0 "$test_status" "duplicate root status"
assert_contains "$test_err" "duplicate root=" "duplicate root warning"
assert_eq "/dev/system/root_b" "$KEEL_ROOT" "duplicate root last wins"
parse_case "root=/dev/system/root_a keel.fail=root keel.fail=data"
assert_status 0 "$test_status" "duplicate fail status"
assert_contains "$test_err" "duplicate keel.fail=" "duplicate fail warning"
assert_eq "data" "$KEEL_FAIL" "duplicate fail last wins"
test_finish test-cmdline
