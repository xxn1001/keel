#!/bin/sh
# Assemble the P0 initramfs from the full Buildroot target tree.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
target_dir="${repo_dir}/out/target"
work_dir="${repo_dir}/out/initrd"
images_dir="${repo_dir}/out/images"
archive="${images_dir}/initrd.cpio"

test -x "${target_dir}/bin/busybox" || {
    echo "mkinitrd: missing ${target_dir}/bin/busybox; run tools/build.sh first" >&2
    exit 1
}
test -x "${target_dir}/sbin/lvm" || {
    echo "mkinitrd: missing ${target_dir}/sbin/lvm" >&2
    exit 1
}

rm -rf "${work_dir}"
mkdir -p "${work_dir}/bin" "${work_dir}/sbin" "${work_dir}/lib"
mkdir -p "${work_dir}/etc/lvm/backup" "${work_dir}/etc/lvm/archive"
mkdir -p "${work_dir}/run/lvm" "${work_dir}/run/lock"
mkdir -p "${work_dir}/usr"
ln -s lib "${work_dir}/lib64"
ln -s ../lib "${work_dir}/usr/lib"
mkdir -p "${images_dir}"

install -m 0755 "${repo_dir}/board/common/initrd/init" "${work_dir}/init"
install -m 0644 "${repo_dir}/board/common/initrd/lib/cmdline.sh" "${work_dir}/lib/cmdline.sh"
install -m 0644 "${repo_dir}/board/common/initrd/lib/discover.sh" "${work_dir}/lib/discover.sh"

python3 "${repo_dir}/tools/lib/collect-deps.py" \
    "${target_dir}" "${work_dir}/bin" "${work_dir}/lib" \
    "${target_dir}/bin/busybox"
python3 "${repo_dir}/tools/lib/collect-deps.py" \
    "${target_dir}" "${work_dir}/sbin" "${work_dir}/lib" \
    "${target_dir}/sbin/lvm" "${target_dir}/sbin/dmsetup"

"${work_dir}/lib/ld-linux-x86-64.so.2" --library-path "${work_dir}/lib" \
    "${work_dir}/bin/busybox" --install -s "${work_dir}/bin"
for link in "${work_dir}"/bin/*; do
    [ -L "${link}" ] && ln -sfn busybox "${link}"
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
        echo "mkinitrd: cpio lacks --owner and fakeroot is unavailable" >&2
        exit 1
    fi
    mv "${tmp}" "${output}"
}

cpio_newc "${work_dir}" "${archive}"
printf 'mkinitrd: %s\n' "${archive}"
