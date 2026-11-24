#!/bin/sh
# Build a Unified Kernel Image with the host's ukify.
#
# The stub always comes from the target tree, never from the host: the
# stub and the target systemd must be the same version.
set -eu

uki_die() {
    echo "mkuki: $*" >&2
    exit 1
}

# uki_cmdline <root device>
uki_cmdline() {
    printf 'root=%s ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1' "$1"
}

uki_find_ukify() {
    if command -v ukify >/dev/null 2>&1; then
        command -v ukify
        return 0
    fi
    for candidate in /usr/lib/systemd/ukify /usr/bin/ukify; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    uki_die "ukify not found; install the systemd ukify tool (systemd package, or systemd-ukify on Debian/Ubuntu)"
}

# Buildroot puts its host python3 first in PATH. ukify's shebang uses
# "env python3", and that interpreter lacks pefile, so drop out/host from
# PATH before running the host ukify.
uki_host_path() {
    _uki_repo=$1
    _uki_path=
    _uki_ifs=$IFS
    IFS=:
    for _uki_dir in $PATH; do
        case "$_uki_dir" in
            "$_uki_repo/out/host"|"$_uki_repo/out/host/"*) continue ;;
        esac
        if [ -z "$_uki_path" ]; then
            _uki_path=$_uki_dir
        else
            _uki_path="${_uki_path}:${_uki_dir}"
        fi
    done
    IFS=$_uki_ifs
    printf '%s\n' "$_uki_path"
}

uki_usage() {
    cat <<'EOF'
usage: tools/mkuki.sh --root <device> --output <file>

  --root    value for root= in the UKI command line
  --output  output .efi path
EOF
}

uki_main() {
    set -eu

    repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
    stub="${repo_dir}/out/target/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    osrel="${repo_dir}/out/target/usr/lib/os-release"
    kernel="${repo_dir}/out/images/bzImage"
    initrd="${repo_dir}/out/images/initrd.cpio"
    root=
    output=

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root)
                [ "$#" -ge 2 ] || uki_die "--root needs a value"
                root=$2
                shift 2
                ;;
            --output)
                [ "$#" -ge 2 ] || uki_die "--output needs a value"
                output=$2
                shift 2
                ;;
            -h|--help)
                uki_usage
                exit 0
                ;;
            *)
                uki_die "unknown argument: $1"
                ;;
        esac
    done

    [ -n "$root" ] || uki_die "--root is required"
    [ -n "$output" ] || uki_die "--output is required"
    test -f "$stub" || uki_die "missing stub: $stub"
    test -f "$osrel" || uki_die "missing os-release: $osrel"
    test -f "$kernel" || uki_die "missing kernel: $kernel"
    test -f "$initrd" || uki_die "missing initrd: $initrd"

    ukify=$(uki_find_ukify)
    PATH=$(uki_host_path "$repo_dir")
    mkdir -p "$(dirname -- "$output")"

    if ! "$ukify" build \
        --linux "$kernel" \
        --initrd "$initrd" \
        --cmdline "$(uki_cmdline "$root")" \
        --os-release "@${osrel}" \
        --stub "$stub" \
        --output "$output"; then
        uki_die "ukify build failed; check its Python dependencies (python-pefile on Arch, python3-pefile on Debian/Ubuntu)"
    fi

    printf 'mkuki: %s (ukify %s)\n' "$output" "$ukify"
}

# Run only when executed, not when sourced for tests.
if (return 0 2>/dev/null); then
    :
else
    uki_main "$@"
fi
