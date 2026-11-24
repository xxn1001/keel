#!/bin/sh
# keel initrd partition discovery. Source only; no side effects.

_keel_read_uevent() {
    _keel_type=
    _keel_name=
    _keel_major=
    _keel_minor=
    while IFS='=' read -r _keel_key _keel_value; do
        case "$_keel_key" in
            DEVTYPE) _keel_type=$_keel_value ;;
            PARTNAME) _keel_name=$_keel_value ;;
            MAJOR) _keel_major=$_keel_value ;;
            MINOR) _keel_minor=$_keel_value ;;
        esac
    done < "$1"
}

_keel_disk_of() {
    _keel_name=${1##*/}
    _keel_target=$(readlink -f "$_keel_sysfs/class/block/$_keel_name" \
        2>/dev/null || true)
    [ -n "$_keel_target" ] || return 1
    _keel_parent=${_keel_target%/*}
    printf '%s\n' "${_keel_parent##*/}"
}

# Store a label/device pair and reject a second device for the same label.
_keel_take_part() {
    case "$1" in
        system) _keel_var=KEEL_DEV_SYSTEM ;;
        recovery) _keel_var=KEEL_DEV_RECOVERY ;;
        data) _keel_var=KEEL_DEV_DATA ;;
        esp) _keel_var=KEEL_DEV_ESP ;;
        *) return 1 ;;
    esac
    eval "_keel_current=\${$_keel_var:-}"
    if [ -n "$_keel_current" ] && [ "$_keel_current" != "$2" ]; then
        echo "keel: discover: candidate $1=$_keel_current"
        echo "keel: discover: candidate $1=$2"
        return 1
    fi
    eval "$_keel_var=\$2"
    return 0
}

# Find the anchor disk with PARTNAME=system, then resolve labels only on it.
keel_discover() {
    _keel_sysfs=${KEEL_SYSFS:-/sys}
    _keel_dev=${KEEL_DEV:-/dev}
    _KEEL_DISCOVER_REASON=
    KEEL_DISK=
    KEEL_DEV_SYSTEM=
    KEEL_DEV_RECOVERY=
    KEEL_DEV_DATA=
    KEEL_DEV_ESP=
    _keel_count=0
    _keel_disks=" "
    _keel_list=

    for _keel_path in "$_keel_sysfs"/class/block/*/uevent; do
        [ -f "$_keel_path" ] || continue
        _keel_part=${_keel_path%/uevent}
        _keel_part=${_keel_part##*/}
        _keel_read_uevent "$_keel_path"
        [ "$_keel_type" = partition ] || continue
        [ "$_keel_name" = system ] || continue
        _keel_disk=$(_keel_disk_of "$_keel_part") || continue
        _keel_count=$((_keel_count + 1))
        _keel_list="${_keel_list} ${_keel_part}:${_keel_disk}"
        case "$_keel_disks" in
            *" $_keel_disk "*) ;;
            *) _keel_disks="${_keel_disks}${_keel_disk} " ;;
        esac
    done

    if [ "$_keel_count" -eq 0 ] && command -v blkid >/dev/null 2>&1; then
        _keel_systems=$(blkid -c /dev/null -t PARTLABEL=system -o device 2>/dev/null || true)
        # shellcheck disable=SC2086
        for _keel_path in $_keel_systems; do
            _keel_part=${_keel_path##*/}
            _keel_disk=$(_keel_disk_of "$_keel_part") || continue
            _keel_count=$((_keel_count + 1))
            _keel_list="${_keel_list} ${_keel_part}:${_keel_disk}"
            case "$_keel_disks" in
                *" $_keel_disk "*) ;;
                *) _keel_disks="${_keel_disks}${_keel_disk} " ;;
            esac
        done
    fi

    [ "$_keel_count" -gt 0 ] || { _KEEL_DISCOVER_REASON=missing; return 3; }

    if [ "$_keel_count" -gt 1 ]; then
        # shellcheck disable=SC2086
        for _keel_entry in $_keel_list; do
            echo "keel: discover: candidate system=${_keel_entry%%:*} disk=${_keel_entry##*:}"
        done
        echo "keel: error: multiple system partitions found"
        _KEEL_DISCOVER_REASON=ambiguous
        return 3
    fi

    _keel_disk=${_keel_disks# }
    _keel_disk=${_keel_disk%% *}
    _keel_entry=${_keel_list# }
    KEEL_DEV_SYSTEM=${_keel_entry%%:*}

    for _keel_path in "$_keel_sysfs"/class/block/*/uevent; do
        [ -f "$_keel_path" ] || continue
        _keel_part=${_keel_path%/uevent}
        _keel_part=${_keel_part##*/}
        _keel_read_uevent "$_keel_path"
        [ "$_keel_type" = partition ] || continue
        case "$_keel_name" in system|recovery|data|esp) ;; *) continue ;; esac
        _keel_owner=$(_keel_disk_of "$_keel_part") || continue
        [ "$_keel_owner" = "$_keel_disk" ] || continue
        if ! _keel_take_part "$_keel_name" "$_keel_part"; then
            echo "keel: error: duplicate $_keel_name partition on $_keel_disk"
            _KEEL_DISCOVER_REASON=ambiguous
            return 3
        fi
    done

    # Kernels without PARTNAME, or a missing label, fall back to blkid.
    if command -v blkid >/dev/null 2>&1; then
        for _keel_label in recovery data esp; do
            case "$_keel_label" in
                recovery) _keel_var=KEEL_DEV_RECOVERY ;;
                data) _keel_var=KEEL_DEV_DATA ;;
                esp) _keel_var=KEEL_DEV_ESP ;;
            esac
            eval "_keel_current=\${$_keel_var:-}"
            [ -n "$_keel_current" ] && continue
            _keel_parts=$(blkid -c /dev/null -t "PARTLABEL=$_keel_label" \
                -o device 2>/dev/null || true)
            # shellcheck disable=SC2086
            for _keel_path in $_keel_parts; do
                _keel_part=${_keel_path##*/}
                _keel_owner=$(_keel_disk_of "$_keel_part") || continue
                [ "$_keel_owner" = "$_keel_disk" ] || continue
                if ! _keel_take_part "$_keel_label" "$_keel_part"; then
                    echo "keel: error: duplicate $_keel_label partition on $_keel_disk"
                    _KEEL_DISCOVER_REASON=ambiguous
                    return 3
                fi
            done
        done
    fi

    KEEL_DISK=$_keel_disk
    printf 'keel: discover: disk=%s system=%s recovery=%s data=%s esp=%s\n' \
        "$KEEL_DISK" "$KEEL_DEV_SYSTEM" "$KEEL_DEV_RECOVERY" \
        "$KEEL_DEV_DATA" "$KEEL_DEV_ESP"
    return 0
}

# Create /dev/disk/by-partlabel links. devtmpfs nodes are expected to exist;
# mknod is only a fallback when a node is missing.
keel_install_links() {
    _keel_sysfs=${KEEL_SYSFS:-/sys}
    _keel_dev=${KEEL_DEV:-/dev}
    _keel_linkdir="$_keel_dev/disk/by-partlabel"
    mkdir -p "$_keel_linkdir"
    for _keel_pair in system:KEEL_DEV_SYSTEM recovery:KEEL_DEV_RECOVERY \
        data:KEEL_DEV_DATA esp:KEEL_DEV_ESP; do
        _keel_label=${_keel_pair%%:*}
        _keel_var=${_keel_pair#*:}
        eval "_keel_part=\${$_keel_var:-}"
        _keel_link="$_keel_linkdir/$_keel_label"
        if [ -z "$_keel_part" ]; then
            rm -f "$_keel_link"
            continue
        fi
        if [ ! -e "$_keel_dev/$_keel_part" ]; then
            _keel_uevent="$_keel_sysfs/class/block/$_keel_part/uevent"
            if [ -f "$_keel_uevent" ]; then
                _keel_read_uevent "$_keel_uevent"
            else
                _keel_major=
                _keel_minor=
            fi
            if [ -n "$_keel_major" ] && [ -n "$_keel_minor" ]; then
                if ! mknod "$_keel_dev/$_keel_part" b \
                    "$_keel_major" "$_keel_minor"; then
                    echo "keel: warn: cannot create device node $_keel_part" >&2
                    continue
                fi
            else
                echo "keel: warn: missing device node $_keel_part" >&2
                continue
            fi
        fi
        rm -f "$_keel_link"
        ln -s "../../$_keel_part" "$_keel_link" || \
            echo "keel: warn: cannot link $_keel_label" >&2
    done
    return 0
}
