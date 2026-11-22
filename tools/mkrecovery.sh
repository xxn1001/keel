#!/bin/sh
# Assemble the recovery tree and emit both erofs and cpio forms.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
target_dir="${repo_dir}/out/target-full"
work_dir="${repo_dir}/out/recovery"
images_dir="${repo_dir}/out/images"
erofs_image="${images_dir}/recovery.erofs"
cpio_image="${images_dir}/recovery.cpio"

test -x "${target_dir}/bin/busybox" || {
    echo "mkrecovery: missing ${target_dir}/bin/busybox; run tools/build.sh first" >&2
    exit 1
}

find_tool() {
    for directory in sbin usr/sbin bin usr/bin; do
        if [ -f "${target_dir}/${directory}/$1" ]; then
            printf '%s\n' "${target_dir}/${directory}/$1"
            return 0
        fi
    done
    echo "mkrecovery: missing tool $1" >&2
    return 1
}

lvm=$(find_tool lvm)
dmsetup=$(find_tool dmsetup)
mkfs_erofs=$(find_tool mkfs.erofs)
mkfs_vfat=$(find_tool mkfs.vfat)
mkfs_ext4=$(find_tool mkfs.ext4)
mkfs_btrfs=$(find_tool mkfs.btrfs)
sgdisk=$(find_tool sgdisk)
blkid=$(find_tool blkid)

rm -rf "${work_dir}"
mkdir -p "${work_dir}/bin" "${work_dir}/sbin" "${work_dir}/lib"
mkdir -p "${work_dir}/etc/lvm/backup" "${work_dir}/etc/lvm/archive"
mkdir -p "${work_dir}/run/lvm" "${work_dir}/run/lock"
mkdir -p "${work_dir}/proc" "${work_dir}/sys" "${work_dir}/dev" "${work_dir}/tmp"
mkdir -p "${work_dir}/usr"
ln -s lib "${work_dir}/lib64"
ln -s ../lib "${work_dir}/usr/lib"
mkdir -p "${images_dir}"

install -m 0755 "${repo_dir}/board/common/recovery/init" "${work_dir}/sbin/init"
ln -s sbin/init "${work_dir}/init"

python3 "${repo_dir}/tools/lib/collect-deps.py" \
    "${target_dir}" "${work_dir}/bin" "${work_dir}/lib" \
    "${target_dir}/bin/busybox"
python3 "${repo_dir}/tools/lib/collect-deps.py" \
    "${target_dir}" "${work_dir}/sbin" "${work_dir}/lib" \
    "${lvm}" "${dmsetup}" "${mkfs_erofs}" "${mkfs_vfat}" \
    "${mkfs_ext4}" "${mkfs_btrfs}" "${sgdisk}" "${blkid}"

"${work_dir}/lib/ld-linux-x86-64.so.2" --library-path "${work_dir}/lib" \
    "${work_dir}/bin/busybox" --install -s "${work_dir}/bin"
for link in "${work_dir}"/bin/*; do
    [ -L "${link}" ] && ln -sfn busybox "${link}"
done
for applet in mount dmesg; do
    [ -e "${work_dir}/bin/${applet}" ] || {
        echo "mkrecovery: busybox applet ${applet} missing" >&2
        exit 1
    }
done

for applet in vgchange vgmknodes lvs pvs vgs pvscan lvscan; do
    ln -sfn lvm "${work_dir}/sbin/${applet}"
done

cat > "${work_dir}/etc/lvm/lvm.conf" <<'EOF'
activation {
    udev_sync = 0
    udev_rules = 0
}
devices {
    dir = "/dev"
}
EOF

host_mkfs_erofs="${repo_dir}/out/host/bin/mkfs.erofs"
if [ ! -x "${host_mkfs_erofs}" ]; then
    host_mkfs_erofs=$(command -v mkfs.erofs || true)
fi
[ -n "${host_mkfs_erofs}" ] || {
    echo "mkrecovery: mkfs.erofs not found on host" >&2
    exit 1
}

cpio_newc() {
    directory=$1
    output=$2
    tmp="${output}.tmp"
    rm -f "${tmp}"
    if cpio --help 2>&1 | grep -q -- '--owner'; then
        (cd "${directory}" && find . -print0 | \
            LC_ALL=C cpio --null -o -H newc --owner=0:0 > "${tmp}")
    elif [ -x "${repo_dir}/out/host/bin/fakeroot" ]; then
        (cd "${directory}" && \
            "${repo_dir}/out/host/bin/fakeroot" -- sh -c \
            'chown -R 0:0 . && find . -print0 | cpio --null -o -H newc' \
            > "${tmp}")
    else
        echo "mkrecovery: cpio lacks --owner and fakeroot is unavailable" >&2
        exit 1
    fi
    mv "${tmp}" "${output}"
}

rm -f "${erofs_image}"
"${host_mkfs_erofs}" --all-root "${erofs_image}" "${work_dir}"
cpio_newc "${work_dir}" "${cpio_image}"
printf 'mkrecovery: %s %s\n' "${erofs_image}" "${cpio_image}"
