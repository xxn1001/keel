#!/bin/sh
# Test the UKI section layout helpers in tools/mkuki.sh.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$test_dir/../.." && pwd)
# shellcheck source=/dev/null
. "$test_dir/../initrd/lib.sh"
# shellcheck source=/dev/null
. "$repo_dir/tools/mkuki.sh"

test_tmp="${TMPDIR:-/tmp}/keel-test-mkuki.$$"
mkdir -p "$test_tmp"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

cat > "$test_tmp/pe.txt" <<'EOF'
SectionAlignment	00001000
ImageBase		000000014df90000
EOF

cat > "$test_tmp/hdr.txt" <<'EOF'
Sections:
Idx Name          Size      VMA               LMA               File off  Algn
  0 .text         0001085e  000000014df91000  000000014df91000  00000400  2**4
                  CONTENTS, ALLOC, LOAD, READONLY, CODE
  4 .reloc        00000090  000000014dfa8000  000000014dfa8000  00015200  2**2
                  CONTENTS, LOAD, READONLY, DATA
EOF

uki_layout "$test_tmp/pe.txt" "$test_tmp/hdr.txt" > "$test_tmp/layout.txt"
read -r image_base section_alignment next_rva < "$test_tmp/layout.txt"
assert_eq "0x000000014df90000" "$image_base" "image base"
assert_eq "0x00001000" "$section_alignment" "section alignment"
assert_eq "0x19000" "$next_rva" "first appended rva"

assert_eq "0x1a000" "$(uki_align_up 0x19123 0x1000)" "align up"
assert_eq "0x14dfa9000" "$(uki_place_vma "$image_base" "$next_rva")" "absolute vma"
assert_eq \
    "root=/dev/system/root_a ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1" \
    "$(uki_cmdline /dev/system/root_a)" \
    "cmdline"

test_finish "test-mkuki"
