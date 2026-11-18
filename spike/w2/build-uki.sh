#!/bin/sh
# Build W-2 UKIs with objcopy. Spike code, not product code.
set -eu

repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
out_dir="${repo_dir}/out/spike/w2/uki"
osrel="${repo_dir}/out/target/usr/lib/os-release"
kernel="${repo_dir}/out/images/bzImage"
initrd="${repo_dir}/out/spike/w2/initrd.cpio"

stub=$(find "${repo_dir}/out/build" -path '*src/boot/efi/linux*.efi.stub' -type f | head -n 1)
if [ -z "${stub}" ]; then
    echo "missing systemd-stub under out/build" >&2
    exit 1
fi

for f in "${osrel}" "${kernel}" "${initrd}"; do
    if [ ! -f "${f}" ]; then
        echo "missing input: ${f}" >&2
        exit 1
    fi
done

mkdir -p "${out_dir}"
cp "${osrel}" "${out_dir}/osrel"

# The Buildroot-built stub has a non-zero PE image base (0x14df90000 on this
# host). objcopy --change-section-vma takes an absolute VMA for PE output, not
# an RVA, so add the image base to the documented UKI offsets. Without this the
# sections are written with underflowed RVAs and SizeOfImage stays at the stub
# size.
image_base=$(objdump -p "${stub}" | awk '/ImageBase/{print "0x"$2; exit}')
if [ -z "${image_base}" ]; then
    echo "cannot read stub image base" >&2
    exit 1
fi
osrel_vma=$(printf 0x%x $((image_base + 0x20000)))
cmdline_vma=$(printf 0x%x $((image_base + 0x30000)))
linux_vma=$(printf 0x%x $((image_base + 0x2000000)))
initrd_vma=$(printf 0x%x $((image_base + 0x3000000)))
echo "stub image base ${image_base}"

build_uki() {
    name=$1
    cmdline=$2
    printf '%s\n' "${cmdline}" > "${out_dir}/${name}.cmdline"
    objcopy \
        --add-section ".osrel=${out_dir}/osrel" \
        --change-section-vma ".osrel=${osrel_vma}" \
        --add-section ".cmdline=${out_dir}/${name}.cmdline" \
        --change-section-vma ".cmdline=${cmdline_vma}" \
        --add-section ".linux=${kernel}" \
        --change-section-vma ".linux=${linux_vma}" \
        --add-section ".initrd=${initrd}" \
        --change-section-vma ".initrd=${initrd_vma}" \
        "${stub}" "${out_dir}/${name}"
    echo "built ${out_dir}/${name}"
    objdump -h "${out_dir}/${name}" | grep -E '^[[:space:]]+[0-9]+ \.(osrel|cmdline|linux|initrd|sbat)' || true
}

base_a="console=ttyS0,115200 root=/dev/system/root_a ro rootfstype=erofs panic=-1 systemd.gpt_auto=no"
base_b="console=ttyS0,115200 root=/dev/system/root_b ro rootfstype=erofs panic=-1 systemd.gpt_auto=no"

build_uki "keel-a+10.efi" "${base_a}"
build_uki "keel-b+10.efi" "${base_b}"
build_uki "keel-z-inspect.efi" "${base_a}"
build_uki "keel-z-esp.efi" "${base_a} keel.fail=esp"
build_uki "keel-a-recovery.efi" "${base_a} keel.recovery=1"

echo "stub: ${stub}"
ls -lh "${out_dir}"/*.efi
