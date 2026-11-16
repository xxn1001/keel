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
