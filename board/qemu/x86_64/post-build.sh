#!/bin/sh
# Buildroot post-build hook for keel2 W-0.
set -eu

target_dir=$1

# Buildroot generates /usr/lib/os-release with NAME=Buildroot; replace it.
cat > "${target_dir}/usr/lib/os-release" <<'EOF'
NAME="keel2"
ID=keel2
VERSION="0.1"
VERSION_ID="0.1"
PRETTY_NAME="keel2 v0.1"
EOF
ln -sf ../usr/lib/os-release "${target_dir}/etc/os-release"

# The W-0 root is an initramfs. Critical mounts are not persistent yet.
cat > "${target_dir}/etc/fstab" <<'EOF'
# keel2 W-0: root is an initramfs; no persistent mounts yet.
EOF

# Do not ship a machine identity. systemd generates this on first boot.
: > "${target_dir}/etc/machine-id"

# Keep the full tree for initrd and recovery assembly, then prune write tools
# from the system root. Restore files removed by an earlier run first, so an
# incremental build does not copy an already-pruned target.
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
full_dir="${repo_dir}/out/target-full"
if [ -d "${full_dir}" ]; then
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        if [ -e "${full_dir}${path}" ] && [ ! -e "${target_dir}${path}" ]; then
            mkdir -p "$(dirname "${target_dir}${path}")"
            cp -a "${full_dir}${path}" "${target_dir}${path}"
        fi
    done < "${repo_dir}/board/common/recovery/system-root-exclude.txt"
fi
rm -rf "${full_dir}"
mkdir -p "${full_dir}"
cp -a "${target_dir}/." "${full_dir}/"

while IFS= read -r path; do
    [ -n "${path}" ] || continue
    rm -f "${target_dir}${path}"
done < "${repo_dir}/board/common/recovery/system-root-exclude.txt"
