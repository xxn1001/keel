#!/bin/sh
# Boot the assembled UKI through OVMF and systemd-boot on a scratch ESP.
#
# This is a test harness, not part of the installer. It writes only under
# out/qemu/ and expects the artifacts produced by tools/build.sh.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
images_dir="${repo_dir}/out/images"
work_dir="${repo_dir}/out/qemu"
esp_image="${work_dir}/esp.img"
empty_disk="${work_dir}/empty.raw"
serial_log="${work_dir}/serial.log"
vars_image="${work_dir}/vars.fd"
boot_timeout=${KEEL_QEMU_TIMEOUT:-180}
ovmf_code=${KEEL_OVMF_CODE:-}
ovmf_vars=${KEEL_OVMF_VARS:-}

die() {
    echo "run-uki-smoke: $*" >&2
    exit 1
}

find_ovmf() {
    if [ -n "$ovmf_code" ] || [ -n "$ovmf_vars" ]; then
        [ -n "$ovmf_code" ] && [ -n "$ovmf_vars" ] || \
            die "set both KEEL_OVMF_CODE and KEEL_OVMF_VARS"
        return
    fi
    for base in /usr/share/edk2/x64 /usr/share/edk2-ovmf/x64 /usr/share/OVMF; do
        if [ -f "$base/OVMF_CODE.4m.fd" ] && [ -f "$base/OVMF_VARS.4m.fd" ]; then
            ovmf_code="$base/OVMF_CODE.4m.fd"
            ovmf_vars="$base/OVMF_VARS.4m.fd"
            return
        fi
        if [ -f "$base/OVMF_CODE.fd" ] && [ -f "$base/OVMF_VARS.fd" ]; then
            ovmf_code="$base/OVMF_CODE.fd"
            ovmf_vars="$base/OVMF_VARS.fd"
            return
        fi
    done
    die "OVMF not found; set KEEL_OVMF_CODE and KEEL_OVMF_VARS"
}

find_ovmf

for tool in qemu-system-x86_64 mkfs.vfat mmd mcopy truncate; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
for name in bzImage initrd.cpio keel-a.efi; do
    test -f "${images_dir}/${name}" || die "missing ${images_dir}/${name}; run tools/build.sh"
done
test -f "${repo_dir}/out/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi" || \
    die "missing systemd-boot; run tools/build.sh"

rm -rf "$work_dir"
mkdir -p "$work_dir"
rm -f "$serial_log"

truncate -s 64M "$esp_image"
mkfs.vfat -F 32 -n KEELESP "$esp_image" >/dev/null
mmd -i "$esp_image" ::/EFI ::/EFI/BOOT ::/EFI/Linux ::/loader
mcopy -i "$esp_image" \
    "${repo_dir}/out/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
    ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$esp_image" "${images_dir}/keel-a.efi" ::/EFI/Linux/keel-a.efi
printf 'default keel-a\ntimeout 3\n' > "${work_dir}/loader.conf"
mcopy -i "$esp_image" "${work_dir}/loader.conf" ::/loader/loader.conf

truncate -s 64M "$empty_disk"
cp "$ovmf_vars" "$vars_image"

accel=tcg
[ -w /dev/kvm ] && accel=kvm

qemu-system-x86_64 \
    -accel "$accel" \
    -m 2048 \
    -display none \
    -monitor none \
    -no-reboot \
    -machine q35 \
    -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}" \
    -drive "if=pflash,format=raw,file=${vars_image}" \
    -drive "file=${esp_image},if=virtio,format=raw" \
    -drive "file=${empty_disk},if=virtio,format=raw" \
    -serial "file:${serial_log}" 2> "${work_dir}/qemu.err" &
qemu_pid=$!

elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$boot_timeout" ]; then
        kill "$qemu_pid" 2>/dev/null || true
        break
    fi
    if [ -f "$serial_log" ] && grep -aq 'dropping to shell' "$serial_log"; then
        sleep 2
        kill "$qemu_pid" 2>/dev/null || true
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
wait "$qemu_pid" 2>/dev/null || true

status=0
check() {
    if ! grep -aq "$1" "$serial_log"; then
        echo "run-uki-smoke: missing: $1" >&2
        status=1
    fi
}
check 'Boot in [0-9] s.'
check 'keel2 v0.1'
check 'Linux version'
check 'Command line: root=/dev/system/root_a ro rootfstype=erofs'
check 'Run /init as init process'
check 'keel: discover: timed out after 30s'
check 'keel: error: partition discovery failed; dropping to shell'
check '~ #'

if [ "$status" -ne 0 ]; then
    cat "${work_dir}/qemu.err" >&2
    die "serial log ${serial_log} did not match the expected boot path"
fi

printf 'run-uki-smoke: ok (accel=%s, log=%s)\n' "$accel" "$serial_log"
