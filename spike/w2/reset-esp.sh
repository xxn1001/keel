#!/bin/sh
# Reset the W-2 test ESP to the initial A+10 / B+10 / inspector state.
# Uses mtools, so it does not need root or a loop device.
set -eu

repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
disk="${repo_dir}/out/spike/w2/disk.raw"
uki="${repo_dir}/out/spike/w2/uki"
img="${disk}@@1048576"

export MTOOLS_SKIP_CHECK=1

for f in keel-a.efi keel-a+10.efi keel-b.efi keel-b+10.efi \
         keel-b+2.efi keel-b+1-1.efi keel-b+0-2.efi \
         keel-z-inspect.efi keel-z-esp.efi keel-a-recovery.efi; do
    mdel -i "${img}" "::/EFI/Linux/${f}" 2>/dev/null || true
done

mcopy -i "${img}" "${uki}/keel-a+10.efi" ::/EFI/Linux/keel-a+10.efi
mcopy -i "${img}" "${uki}/keel-b+10.efi" ::/EFI/Linux/keel-b+10.efi
mcopy -i "${img}" "${uki}/keel-z-inspect.efi" ::/EFI/Linux/keel-z-inspect.efi

mcopy -o -i "${img}" "${uki}/keel-a+10.efi" ::/keel/uki/keel-a+10.efi
mcopy -o -i "${img}" "${uki}/keel-b+10.efi" ::/keel/uki/keel-b+10.efi
mcopy -o -i "${img}" "${uki}/keel-z-esp.efi" ::/keel/uki/keel-z-esp.efi
mcopy -o -i "${img}" "${uki}/keel-a-recovery.efi" ::/keel/uki/keel-a-recovery.efi

mdir -i "${img}" ::/EFI/Linux
mdir -i "${img}" ::/keel/uki
