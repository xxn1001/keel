#!/bin/sh
# Build a Unified Kernel Image from the systemd EFI stub.
#
# VMA layout: like systemd's ukify, append each new section at
#   rva(0)   = align_up(last_vma - ImageBase + last_size, SectionAlignment)
#   rva(n+1) = align_up(rva(n) + size(n), SectionAlignment)
# where last_vma/last_size come from the stub's final PE section. objcopy's
# PE writer expects an absolute VMA, so pass ImageBase + rva for every new
# section. ImageBase, SectionAlignment, and the section layout are read from
# objdump; this script hardcodes no addresses.

uki_die() {
    echo "mkuki: $*" >&2
    exit 1
}

uki_align_up() {
    printf '0x%x' $(( ($1 + $2 - 1) / $2 * $2 ))
}

# uki_layout <objdump -p file> <objdump -h file>
# Print "image_base section_alignment next_rva" for the first appended section.
uki_layout() {
    _uki_pe=$1
    _uki_hdr=$2

    _uki_image_base=$(awk '/^ImageBase/ { print $2; exit }' "$_uki_pe")
    _uki_section_align=$(awk '/^SectionAlignment/ { print $2; exit }' "$_uki_pe")
    [ -n "$_uki_image_base" ] || uki_die "no ImageBase in $_uki_pe"
    [ -n "$_uki_section_align" ] || uki_die "no SectionAlignment in $_uki_pe"

    _uki_last=$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^\./ { vma=$4; size=$3 } END { print vma, size }' "$_uki_hdr")
    [ -n "$_uki_last" ] || uki_die "no sections in $_uki_hdr"

    _uki_last_vma=0x${_uki_last%% *}
    _uki_last_size=0x${_uki_last##* }
    _uki_next=$((_uki_last_vma - 0x$_uki_image_base + _uki_last_size))
    _uki_next=$(uki_align_up "$_uki_next" "0x$_uki_section_align")

    printf '0x%s 0x%s %s\n' "$_uki_image_base" "$_uki_section_align" "$_uki_next"
}

uki_place_vma() {
    printf '0x%x' $(( $1 + $2 ))
}

# uki_cmdline <root device>
uki_cmdline() {
    printf 'root=%s ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1' "$1"
}

# uki_check_section <file> <section name> <expected vma>
uki_check_section() {
    _uki_file=$1
    _uki_name=$2
    _uki_expected=$3
    _uki_actual=0x$(objdump -h "$_uki_file" | awk -v name="$_uki_name" '$2 == name { print $4; exit }')
    [ "$_uki_actual" != 0x ] || uki_die "missing section $_uki_name in $_uki_file"
    [ "$((_uki_actual))" -eq "$((_uki_expected))" ] || \
        uki_die "section $_uki_name at $_uki_actual, expected $_uki_expected"
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
    work=
    output_tmp=

    cleanup() {
        [ -z "$work" ] || rm -rf "$work"
        [ -z "$output_tmp" ] || rm -f "$output_tmp"
    }
    trap cleanup EXIT HUP INT TERM

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

    work=$(mktemp -d "${TMPDIR:-/tmp}/mkuki.XXXXXX")
    objdump -p "$stub" > "$work/pe.txt"
    objdump -h "$stub" > "$work/hdr.txt"
    uki_layout "$work/pe.txt" "$work/hdr.txt" > "$work/layout.txt"
    read -r image_base section_alignment next_rva < "$work/layout.txt"

    uki_cmdline "$root" > "$work/cmdline"

    osrel_vma=$(uki_place_vma "$image_base" "$next_rva")
    next_rva=$(uki_align_up "$((next_rva + $(stat -c %s "$osrel")))" "$section_alignment")
    cmdline_vma=$(uki_place_vma "$image_base" "$next_rva")
    next_rva=$(uki_align_up "$((next_rva + $(stat -c %s "$work/cmdline")))" "$section_alignment")
    linux_vma=$(uki_place_vma "$image_base" "$next_rva")
    next_rva=$(uki_align_up "$((next_rva + $(stat -c %s "$kernel")))" "$section_alignment")
    initrd_vma=$(uki_place_vma "$image_base" "$next_rva")

    mkdir -p "$(dirname -- "$output")"
    output_tmp="${output}.tmp.$$"
    objcopy \
        --add-section ".osrel=${osrel}" \
        --change-section-vma ".osrel=${osrel_vma}" \
        --add-section ".cmdline=${work}/cmdline" \
        --change-section-vma ".cmdline=${cmdline_vma}" \
        --add-section ".linux=${kernel}" \
        --change-section-vma ".linux=${linux_vma}" \
        --add-section ".initrd=${initrd}" \
        --change-section-vma ".initrd=${initrd_vma}" \
        "$stub" "$output_tmp"

    uki_check_section "$output_tmp" .osrel "$osrel_vma"
    uki_check_section "$output_tmp" .cmdline "$cmdline_vma"
    uki_check_section "$output_tmp" .linux "$linux_vma"
    uki_check_section "$output_tmp" .initrd "$initrd_vma"

    mv "$output_tmp" "$output"
    output_tmp=
    printf 'mkuki: %s (ImageBase %s)\n' "$output" "$image_base"
}

# Run only when executed, not when sourced for tests.
if (return 0 2>/dev/null); then
    :
else
    uki_main "$@"
fi
