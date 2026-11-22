#!/bin/sh
# Assertion helpers for the initrd tests. Source this file.
TEST_FAILURES=0
test_fail() {
    echo "FAIL: $*" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
}
assert_eq() {
    [ "$1" = "$2" ] || test_fail "$3: expected '$1', got '$2'"
}
assert_status() {
    [ "$1" -eq "$2" ] || test_fail "$3: expected status $1, got $2"
}
assert_empty() {
    [ -z "$1" ] || test_fail "$2: expected empty, got '$1'"
}
assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) test_fail "$3: missing '$2'" ;;
    esac
}
assert_link_target() {
    if [ ! -L "$1" ]; then
        test_fail "$3: $1 is not a symlink"
        return
    fi
    _assert_actual=$(readlink "$1")
    assert_eq "$2" "$_assert_actual" "$3"
}
assert_not_exists() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        test_fail "$2: $1 exists"
    fi
}
test_finish() {
    if [ "$TEST_FAILURES" -ne 0 ]; then
        echo "$1: failed"
        exit 1
    fi
    echo "$1: ok"
}
