#!/bin/bash
# W-2 boot chain spike provisioning. Run with sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run with sudo: sudo $0" >&2
    exit 1
fi

REPO=${REPO:-/home/admin/Projects/keel}
SPIKE="$REPO/out/spike/w2"
DISK="$SPIKE/disk.raw"
ROOTFS="$SPIKE/rootfs"
MOUNT="$SPIKE/mnt"
ESP="$SPIKE/esp"
LOG="$SPIKE/provision.log"
UKI="$REPO/out/spike/w2/uki"
LOOP=""

mkdir -p "$SPIKE"
if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:" "$SPIKE"
    chmod 0755 "$SPIKE"
fi
exec > >(tee "$LOG") 2>&1

cleanup() {
    set +e
    echo "== cleanup"
    umount "$ESP" 2>/dev/null || true
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

echo "== W-2 provision started $(date -Is)"
echo "== repo=$REPO"
test -f "$REPO/out/images/rootfs.tar" || { echo "missing rootfs.tar" >&2; exit 1; }
test -f "$REPO/out/images/efi-part/EFI/BOOT/bootx64.efi" || { echo "missing systemd-boot binary" >&2; exit 1; }
test -x "$REPO/out/target/usr/bin/bootctl" || { echo "target has no bootctl" >&2; exit 1; }
test -x "$REPO/out/target/usr/lib/systemd/systemd-bless-boot" || { echo "target has no systemd-bless-boot" >&2; exit 1; }
test -f "$UKI/keel-a+10.efi" || { echo "missing keel-a+10.efi" >&2; exit 1; }
test -f "$UKI/keel-b+10.efi" || { echo "missing keel-b+10.efi" >&2; exit 1; }
test -f "$UKI/keel-z-inspect.efi" || { echo "missing keel-z-inspect.efi" >&2; exit 1; }
test -f "$UKI/keel-z-esp.efi" || { echo "missing keel-z-esp.efi" >&2; exit 1; }
test -f "$UKI/keel-a-recovery.efi" || { echo "missing keel-a-recovery.efi" >&2; exit 1; }

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

echo "== extract rootfs and add W-2 units"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xf "$REPO/out/images/rootfs.tar" -C "$ROOTFS"
cp -a "$REPO/spike/w2/rootfs-overlay/." "$ROOTFS/"
test -x "$ROOTFS/usr/libexec/keel/keel-boot-ok" || { echo "missing boot-ok helper" >&2; exit 1; }
test -x "$ROOTFS/usr/libexec/keel/keel-boot-repair" || { echo "missing boot-repair helper" >&2; exit 1; }

echo "== mkfs.erofs on both root LVs"
mkfs.erofs --all-root /dev/system/root_a "$ROOTFS"
mkfs.erofs --all-root /dev/system/root_b "$ROOTFS"

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

echo "== install systemd-boot and UKIs on the ESP"
mkdir -p "$ESP"
mount "${LOOP}p1" "$ESP"
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/Linux" "$ESP/loader" "$ESP/keel/uki"
install -m 0644 "$REPO/out/images/efi-part/EFI/BOOT/bootx64.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
printf 'timeout 1\n' > "$ESP/loader/loader.conf"
install -m 0644 "$UKI/keel-a+10.efi" "$ESP/EFI/Linux/keel-a+10.efi"
install -m 0644 "$UKI/keel-b+10.efi" "$ESP/EFI/Linux/keel-b+10.efi"
install -m 0644 "$UKI/keel-z-inspect.efi" "$ESP/EFI/Linux/keel-z-inspect.efi"
install -m 0644 "$UKI/keel-a+10.efi" "$ESP/keel/uki/keel-a+10.efi"
install -m 0644 "$UKI/keel-b+10.efi" "$ESP/keel/uki/keel-b+10.efi"
install -m 0644 "$UKI/keel-z-esp.efi" "$ESP/keel/uki/keel-z-esp.efi"
install -m 0644 "$UKI/keel-a-recovery.efi" "$ESP/keel/uki/keel-a-recovery.efi"
sync
echo "== ESP files"
find "$ESP" -type f -printf '%P %s\n' | sort
umount "$ESP"

echo "== filesystem metadata"
dumpe2fs -h /dev/system/etc 2>/dev/null | head -20 || true
btrfs filesystem show "${LOOP}p4" || true
blkid "${LOOP}p1" "${LOOP}p3" "${LOOP}p4" /dev/system/root_a /dev/system/root_b /dev/system/etc || true

echo "== LVM state"
pvs
vgs
lvs -a -o +devices

echo "== W-2 provision done; cleaning up"
