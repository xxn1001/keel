#!/bin/sh
# Download and extract the pinned Buildroot release into vendor/buildroot.
set -eu

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
. "${repo_dir}/versions.env"

: "${BUILDROOT_VERSION:?}"
: "${BUILDROOT_URL:?}"
: "${BUILDROOT_SHA256:?}"

vendor_dir="${repo_dir}/vendor"
source_dir="${vendor_dir}/buildroot"

case "${BUILDROOT_URL}" in
    *.tar.xz)
        tarball="${vendor_dir}/buildroot-${BUILDROOT_VERSION}.tar.xz"
        tar_flags="-xJf"
        ;;
    *.tar.gz)
        tarball="${vendor_dir}/buildroot-${BUILDROOT_VERSION}.tar.gz"
        tar_flags="-xzf"
        ;;
    *)
        echo "bootstrap-buildroot: unsupported tarball URL: ${BUILDROOT_URL}" >&2
        exit 1
        ;;
esac

mkdir -p "${vendor_dir}"

if [ -e "${source_dir}" ]; then
    if [ -f "${source_dir}/Makefile" ] && \
       grep -q "^export BR2_VERSION := ${BUILDROOT_VERSION}$" "${source_dir}/Makefile"; then
        echo "bootstrap-buildroot: Buildroot ${BUILDROOT_VERSION} already extracted"
        exit 0
    fi
    echo "bootstrap-buildroot: ${source_dir} exists but is not Buildroot ${BUILDROOT_VERSION}" >&2
    echo "bootstrap-buildroot: remove it manually to re-extract" >&2
    exit 1
fi

if [ ! -f "${tarball}" ]; then
    echo "bootstrap-buildroot: downloading ${BUILDROOT_URL}"
    curl -fL --retry 3 --connect-timeout 30 -o "${tarball}.part" "${BUILDROOT_URL}"
    mv "${tarball}.part" "${tarball}"
fi

echo "${BUILDROOT_SHA256}  ${tarball}" | sha256sum -c -
mkdir -p "${source_dir}"
tar ${tar_flags} "${tarball}" -C "${source_dir}" --strip-components=1

test -f "${source_dir}/Makefile"
echo "bootstrap-buildroot: extracted Buildroot ${BUILDROOT_VERSION} to ${source_dir}"
