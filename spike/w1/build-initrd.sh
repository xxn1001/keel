#!/bin/sh
# Build the W-1 minimal initramfs from the Buildroot target tree.
# One-time spike code, not product code.
set -eu

repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
target_dir="${repo_dir}/out/target"
initrd_dir="${repo_dir}/out/spike/initrd"
initrd_cpio="${repo_dir}/out/spike/initrd.cpio"

rm -rf "${initrd_dir}"
mkdir -p "${initrd_dir}/bin" "${initrd_dir}/sbin" "${initrd_dir}/lib"
mkdir -p "${initrd_dir}/dev" "${initrd_dir}/proc" "${initrd_dir}/sys"
mkdir -p "${initrd_dir}/run/keel" "${initrd_dir}/run/lvm" "${initrd_dir}/run/lock"
mkdir -p "${initrd_dir}/sysroot" "${initrd_dir}/recovery"
mkdir -p "${initrd_dir}/etc/lvm/backup" "${initrd_dir}/etc/lvm/archive"
mkdir -p "${initrd_dir}/usr"
ln -s lib "${initrd_dir}/lib64"
ln -s ../lib "${initrd_dir}/usr/lib"

install -m 0755 "${target_dir}/bin/busybox" "${initrd_dir}/bin/busybox"
"${initrd_dir}/bin/busybox" --install -s "${initrd_dir}/bin"
# busybox --install -s creates absolute links to the build tree; make them
# relative so they resolve inside the initramfs.
for link in "${initrd_dir}"/bin/*; do
    if [ -L "${link}" ]; then
        ln -sfn busybox "${link}"
    fi
done

install -m 0755 "${target_dir}/sbin/lvm" "${initrd_dir}/sbin/lvm"
install -m 0755 "${target_dir}/sbin/dmsetup" "${initrd_dir}/sbin/dmsetup"
for applet in vgchange vgmknodes lvs pvs vgs pvscan lvscan; do
    ln -sf lvm "${initrd_dir}/sbin/${applet}"
done

python3 - "${target_dir}" "${initrd_dir}" <<'PY'
import os
import shutil
import subprocess
import sys

target = sys.argv[1]
initrd = sys.argv[2]
lib_dir = os.path.join(target, "usr", "lib")

index = {}
for dirpath, _dirnames, filenames in os.walk(lib_dir):
    for name in filenames:
        if ".so" in name:
            index.setdefault(name, os.path.join(dirpath, name))

queue = [
    os.path.join(target, "bin", "busybox"),
    os.path.join(target, "sbin", "lvm"),
    os.path.join(target, "sbin", "dmsetup"),
]
seen = set()
while queue:
    path = queue.pop()
    if path in seen:
        continue
    seen.add(path)
    output = subprocess.check_output(["readelf", "-d", path], text=True)
    for line in output.splitlines():
        if "(NEEDED)" not in line:
            continue
        name = line.split("[", 1)[1].split("]", 1)[0]
        src = index.get(name)
        if src is None:
            print(f"missing target library: {name} (needed by {path})", file=sys.stderr)
            sys.exit(1)
        dest = os.path.join(initrd, "lib", name)
        if not os.path.exists(dest):
            shutil.copy2(src, dest)
        queue.append(src)

loader = index.get("ld-linux-x86-64.so.2")
if loader is None:
    print("missing target dynamic loader", file=sys.stderr)
    sys.exit(1)
shutil.copy2(loader, os.path.join(initrd, "lib", "ld-linux-x86-64.so.2"))
PY

cat > "${initrd_dir}/etc/lvm/lvm.conf" <<'EOF'
activation {
    udev_sync = 0
    udev_rules = 0
}
devices {
    dir = "/dev"
}
EOF

install -m 0755 "${repo_dir}/spike/w1/init" "${initrd_dir}/init"

if [ -x "${repo_dir}/out/host/bin/fakeroot" ]; then
    "${repo_dir}/out/host/bin/fakeroot" -- sh -c \
        "chown -R 0:0 '${initrd_dir}'; cd '${initrd_dir}'; find . -print0 | cpio --null -o -H newc > '${initrd_cpio}'"
else
    (cd "${initrd_dir}" && find . -print0 | cpio --null -o -H newc > "${initrd_cpio}")
fi

ls -lh "${initrd_cpio}"
