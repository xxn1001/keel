#!/bin/bash
# W-1 storage spike provisioning. Run with sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run with sudo: sudo $0" >&2
    exit 1
fi

REPO=${REPO:-/home/admin/Projects/keel}
SPIKE="$REPO/out/spike"
# losetup maps the file bytes, not a qcow2 virtual disk. Use a raw sparse
# image for host provisioning and for the W-1 QEMU drive.
DISK="$SPIKE/disk.raw"
ROOTFS="$SPIKE/rootfs"
MOUNT="$SPIKE/mnt"
LOG="$SPIKE/provision.log"
LOOP=""

mkdir -p "$SPIKE"
exec > >(tee "$LOG") 2>&1

cleanup() {
    set +e
    echo "== cleanup"
    umount "$MOUNT" 2>/dev/null || true
    sync
    vgchange -an system 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || {
            sleep 1
            losetup -d "$LOOP" 2>/dev/null || true
        }
    fi
    udevadm settle 2>/dev/null || true
    echo "== vgs after cleanup"
    vgs system 2>&1 || true
    echo "== losetup after cleanup"
    losetup -a | grep -F "$DISK" || true
}
trap cleanup EXIT

echo "== W-1 provision started $(date -Is)"
echo "== repo=$REPO"
test -d "$ROOTFS" || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }
test -x "$ROOTFS/usr/lib/systemd/systemd" || { echo "rootfs has no systemd" >&2; exit 1; }
test -x "$ROOTFS/usr/sbin/lvs" || { echo "rootfs has no lvs" >&2; exit 1; }
test -x "$ROOTFS/usr/bin/findmnt" || { echo "rootfs has no findmnt" >&2; exit 1; }

# Stop a previous VG and detach any loop that still points at this disk.
vgchange -an system 2>/dev/null || true
while read -r stale; do
    [ -n "$stale" ] && losetup -d "$stale" 2>/dev/null || true
done < <(losetup -j "$DISK" 2>/dev/null | cut -d: -f1)

rm -f "$DISK"
truncate -s 64G "$DISK"
if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:" "$DISK"
fi
LOOP=$(losetup -fP --show "$DISK")
echo "== loop=$LOOP"

sgdisk --zap-all "$LOOP"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:esp "$LOOP"
sgdisk -n 2:0:+1G -t 2:8300 -c 2:recovery "$LOOP"
sgdisk -n 3:0:+6G -t 3:8e00 -c 3:system "$LOOP"
sgdisk -n 4:0:0 -t 4:8300 -c 4:data "$LOOP"
partx -u "$LOOP"
udevadm settle

for i in 1 2 3 4; do
    for _ in $(seq 1 20); do
        [ -b "${LOOP}p${i}" ] && break
        sleep 0.5
    done
    [ -b "${LOOP}p${i}" ] || { echo "missing partition ${LOOP}p${i}" >&2; exit 1; }
done

echo "== partition table"
sgdisk -p "$LOOP"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$LOOP"

pvcreate -ff -y "${LOOP}p3"
vgcreate system "${LOOP}p3"
lvcreate -y -n root_a -L 2G system
lvcreate -y -n root_b -L 2G system
lvcreate -y -n etc -L 1G system

echo "== A-001: mkfs.erofs direct to LV"
set +e
mkfs.erofs --all-root /dev/system/root_a "$ROOTFS"
erofs_rc=$?
set -e
echo "mkfs.erofs rc=$erofs_rc"
if [ "$erofs_rc" -ne 0 ]; then
    echo "A-001 RESULT: REFUTED: mkfs.erofs cannot write the LV path directly"
    exit 10
fi
echo "A-001 RESULT: PASS: mkfs.erofs wrote /dev/system/root_a directly"
dump.erofs /dev/system/root_a | head -80 || true

mkfs.ext4 -F -L etc /dev/system/etc
mkfs.vfat -F32 -n esp "${LOOP}p1"
mkfs.btrfs -f -L data "${LOOP}p4"

echo "== seed /etc from the rootfs"
mkdir -p "$MOUNT"
mount /dev/system/etc "$MOUNT"
cp -a "$ROOTFS/etc/." "$MOUNT/"
chown -R 0:0 "$MOUNT"
umount "$MOUNT"

mkdir -p "$MOUNT"
mount "${LOOP}p4" "$MOUNT"
btrfs subvolume create "$MOUNT/var"
btrfs subvolume create "$MOUNT/home"
umount "$MOUNT"

echo "== filesystem metadata"
dumpe2fs -h /dev/system/etc 2>/dev/null | head -30 || true
btrfs filesystem show "${LOOP}p4" || true
blkid "${LOOP}p1" "${LOOP}p3" "${LOOP}p4" /dev/system/root_a /dev/system/etc || true

echo "== LVM state"
pvs
vgs
lvs -a -o +devices

echo "== W-1 provision done; cleaning up"
echo "A-001: mkfs.erofs direct LV write PASS"
