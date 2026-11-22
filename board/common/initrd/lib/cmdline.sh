#!/bin/sh
# keel initrd cmdline parsing. Source only; no side effects.
# The KEEL_* assignments are the public output of this file.
# shellcheck disable=SC2034

_keel_warn() {
    echo "keel: warn: $*" >&2
}

# Return 0 when the key was already seen, 1 when it is new.
_keel_mark_seen() {
    case "$_keel_seen" in
        *"|$1|"*) return 0 ;;
    esac
    _keel_seen="${_keel_seen}$1|"
    return 1
}

_keel_dupe() {
    _keel_mark_seen "$1" && _keel_warn "$2"
}

# keel_parse_cmdline "<cmdline string>"
# Sets KEEL_FAIL, KEEL_RECOVERY, KEEL_ROOT, and KEEL_T_*.
# Returns 0 normally, 2 when root= is not on the whitelist.
keel_parse_cmdline() {
    KEEL_FAIL=
    KEEL_RECOVERY=0
    KEEL_ROOT=/dev/system/root_a
    KEEL_T_LVM=30
    KEEL_T_ROOT=15
    KEEL_T_ETC=15
    KEEL_T_DATA=15
    KEEL_T_ESP=10
    _keel_seen="|"
    case "$-" in *f*) _keel_had_noglob=1 ;; *) _keel_had_noglob=0 ;; esac
    set -f
    # Word splitting is intended; the kernel passes one space-separated string.
    # shellcheck disable=SC2086
    set -- $1
    while [ "$#" -gt 0 ]; do
        _keel_arg=$1
        shift
        case "$_keel_arg" in
            root=*)
                _keel_dupe root "duplicate root=, using last value"
                KEEL_ROOT=${_keel_arg#root=}
                ;;
            keel.recovery=*)
                _keel_dupe recovery "duplicate keel.recovery=, using last value"
                _keel_value=${_keel_arg#keel.recovery=}
                case "$_keel_value" in
                    0|1) KEEL_RECOVERY=$_keel_value ;;
                    *) _keel_warn "invalid keel.recovery=$_keel_value, ignored" ;;
                esac
                ;;
            keel.fail=*)
                _keel_dupe fail "duplicate keel.fail=, using last value"
                _keel_value=${_keel_arg#keel.fail=}
                case "$_keel_value" in
                    vglv|root|etc|data|esp) KEEL_FAIL=$_keel_value ;;
                    *) _keel_warn "invalid keel.fail=$_keel_value, ignored" ;;
                esac
                ;;
            keel.timeout=*)
                _keel_kv=${_keel_arg#keel.timeout=}
                case "$_keel_kv" in
                    *:*) ;;
                    *) _keel_warn "invalid keel.timeout=$_keel_kv, ignored"; continue ;;
                esac
                _keel_name=${_keel_kv%%:*}
                _keel_secs=${_keel_kv#*:}
                case "$_keel_name" in
                    lvm|root|etc|data|esp) ;;
                    *) _keel_warn "unknown timeout name: $_keel_name"; continue ;;
                esac
                _keel_dupe "timeout:$_keel_name" "duplicate keel.timeout=$_keel_name, using last value"
                case "$_keel_secs" in
                    ''|*[!0-9]*) _keel_warn "invalid keel.timeout=$_keel_name:$_keel_secs, ignored"; continue ;;
                esac
                if [ "$_keel_secs" -lt 1 ]; then
                    _keel_secs=1
                    _keel_warn "keel.timeout=$_keel_name:0 clamped to 1"
                elif [ "$_keel_secs" -gt 600 ]; then
                    _keel_secs=600
                    _keel_warn "keel.timeout=$_keel_name out of range, clamped to 600"
                fi
                case "$_keel_name" in
                    lvm) KEEL_T_LVM=$_keel_secs ;;
                    root) KEEL_T_ROOT=$_keel_secs ;;
                    etc) KEEL_T_ETC=$_keel_secs ;;
                    data) KEEL_T_DATA=$_keel_secs ;;
                    esp) KEEL_T_ESP=$_keel_secs ;;
                esac
                ;;
            keel.mode=*)
                _keel_dupe mode "duplicate keel.mode=, using last value"
                ;;
            keel.*)
                _keel_key=${_keel_arg%%=*}
                _keel_dupe "unknown:$_keel_key" "duplicate keel parameter $_keel_key, using last value"
                _keel_warn "unknown parameter $_keel_key, ignored"
                ;;
        esac
    done
    [ "$_keel_had_noglob" -eq 1 ] || set +f
    case "$KEEL_ROOT" in
        /dev/system/root_a|/dev/system/root_b) ;;
        *) echo "keel: error: invalid root=$KEEL_ROOT" >&2; return 2 ;;
    esac
    return 0
}
