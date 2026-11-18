#!/bin/sh
# Refresh the UKIs on the W-2 test ESP after a kernel rebuild.
# Uses mtools, so it does not need root or a loop device.
set -eu

repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
disk="${repo_dir}/out/spike/w2/disk.raw"
uki="${repo_dir}/out/spike/w2/uki"
img="${disk}@@1048576"

export MTOOLS_SKIP_CHECK=1

for f in keel-a+10.efi keel-b+10.efi keel-z-inspect.efi keel-z-esp.efi keel-a-recovery.efi; do
    test -f "${uki}/${f}" || { echo "missing ${uki}/${f}" >&2; exit 1; }
done

mcopy -o -i "${img}" "${uki}/keel-a+10.efi" ::/EFI/Linux/keel-a+10.efi
mcopy -o -i "${img}" "${uki}/keel-b+10.efi" ::/EFI/Linux/keel-b+10.efi
mcopy -o -i "${img}" "${uki}/keel-z-inspect.efi" ::/EFI/Linux/keel-z-inspect.efi
mcopy -o -i "${img}" "${uki}/keel-a+10.efi" ::/keel/uki/keel-a+10.efi
mcopy -o -i "${img}" "${uki}/keel-b+10.efi" ::/keel/uki/keel-b+10.efi
mcopy -o -i "${img}" "${uki}/keel-z-esp.efi" ::/keel/uki/keel-z-esp.efi
mcopy -o -i "${img}" "${uki}/keel-a-recovery.efi" ::/keel/uki/keel-a-recovery.efi

mdir -i "${img}" ::/EFI/Linux
mdir -i "${img}" ::/keel/uki
