#!/bin/sh
# Build the P0 initramfs, recovery images, UKIs, and the artifact manifest.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
images_dir="${repo_dir}/out/images"

"${repo_dir}/tools/mkinitrd.sh"
"${repo_dir}/tools/mkrecovery.sh"
"${repo_dir}/tools/mkuki.sh" --root /dev/system/root_a --output "${images_dir}/keel-a.efi"
"${repo_dir}/tools/mkuki.sh" --root /dev/system/root_b --output "${images_dir}/keel-b.efi"

# The manifest is last: every hash must describe a finished artifact.
manifest="${images_dir}/manifest.txt"
manifest_tmp="${manifest}.tmp"
: > "$manifest_tmp"
for name in bzImage initrd.cpio rootfs.erofs recovery.erofs recovery.cpio keel-a.efi keel-b.efi; do
    file="${images_dir}/${name}"
    test -f "$file" || {
        echo "post-image: missing ${file}" >&2
        exit 1
    }
    sum=$(sha256sum "$file")
    printf '%s  %s  %s\n' "${sum%% *}" "$(stat -c %s "$file")" "$name" >> "$manifest_tmp"
done
mv "$manifest_tmp" "$manifest"
printf 'post-image: %s\n' "$manifest"
