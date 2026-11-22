#!/bin/sh
# Build keel2 images with a job count sized to the host.
#
# This file is safe to source: it only defines functions. Run it directly
# to configure and build; source it to use keel_jobs in tests.

# keel_jobs <nproc> <ram_gib>
# Print min(nproc, ram_gib - 2, 16), with a lower bound of 1.
keel_jobs() {
    _keel_nproc=$1
    _keel_ram_gib=$2
    _keel_jobs=$_keel_nproc
    _keel_ram_jobs=$((_keel_ram_gib - 2))
    if [ "$_keel_jobs" -gt "$_keel_ram_jobs" ]; then
        _keel_jobs=$_keel_ram_jobs
    fi
    if [ "$_keel_jobs" -gt 16 ]; then
        _keel_jobs=16
    fi
    if [ "$_keel_jobs" -lt 1 ]; then
        _keel_jobs=1
    fi
    printf '%s\n' "$_keel_jobs"
}

keel_nproc() {
    _keel_nproc=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    case "$_keel_nproc" in
        ''|*[!0-9]*) _keel_nproc=1 ;;
    esac
    if [ "$_keel_nproc" -lt 1 ]; then
        _keel_nproc=1
    fi
    printf '%s\n' "$_keel_nproc"
}

keel_ram_gib() {
    _keel_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
    case "$_keel_kb" in
        ''|*[!0-9]*) _keel_kb=1048576 ;;
    esac
    _keel_gib=$((_keel_kb / 1024 / 1024))
    if [ "$_keel_gib" -lt 1 ]; then
        _keel_gib=1
    fi
    printf '%s\n' "$_keel_gib"
}

keel_validate_jobs() {
    case "$1" in
        ''|*[!0-9]*)
            echo "keel: jobs must be a positive integer: $1" >&2
            return 1
            ;;
    esac
    if [ "$1" -lt 1 ]; then
        echo "keel: jobs must be at least 1 (BR2_JLEVEL=0 means nproc+1)" >&2
        return 1
    fi
}

keel_usage() {
    cat <<'EOF'
usage: tools/build.sh [--jobs N] [--reconfigure] [--dry-run]

  --jobs N        override the computed job count
  --reconfigure   rerun defconfig even when out/.config exists
  --dry-run       print the commands without running them

The job count comes from --jobs, then KEEL_JOBS in build.local, then
min(nproc, RAM_GiB - 2, 16).
EOF
}

keel_load_local() {
    if [ -f "$1" ]; then
        # shellcheck source=/dev/null
        . "$1"
    fi
}

keel_build_main() {
    set -eu

    repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
    buildroot_dir="$repo_dir/vendor/buildroot"
    out_dir="$repo_dir/out"
    defconfig=keel_qemu_x86_64_defconfig

    jobs_override=
    reconfigure=0
    dry_run=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --jobs)
                if [ "$#" -lt 2 ]; then
                    echo "keel: --jobs needs a value" >&2
                    return 2
                fi
                jobs_override=$2
                shift 2
                ;;
            --jobs=*)
                jobs_override=${1#*=}
                shift
                ;;
            --reconfigure)
                reconfigure=1
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            -h|--help)
                keel_usage
                return 0
                ;;
            *)
                echo "keel: unknown argument: $1" >&2
                keel_usage >&2
                return 2
                ;;
        esac
    done

    nproc=$(keel_nproc)
    ram_gib=$(keel_ram_gib)
    keel_load_local "$repo_dir/build.local"

    if [ -n "$jobs_override" ]; then
        jobs=$jobs_override
    elif [ -n "${KEEL_JOBS:-}" ]; then
        jobs=$KEEL_JOBS
    else
        jobs=$(keel_jobs "$nproc" "$ram_gib")
    fi
    keel_validate_jobs "$jobs"

    if [ ! -f "$buildroot_dir/Makefile" ]; then
        echo "keel: Buildroot not found; run tools/bootstrap-buildroot.sh first" >&2
        return 1
    fi

    cd "$repo_dir"

    if [ ! -f "$out_dir/.config" ] || [ "$reconfigure" -eq 1 ]; then
        defconfig_cmd="make -C vendor/buildroot BR2_EXTERNAL=$repo_dir O=$out_dir $defconfig"
        if [ "$dry_run" -eq 1 ]; then
            printf '%s\n' "$defconfig_cmd"
        else
            make -C vendor/buildroot BR2_EXTERNAL="$repo_dir" O="$out_dir" "$defconfig"
        fi
    fi

    build_cmd="make -C out BR2_JLEVEL=$jobs"
    if [ "$dry_run" -eq 1 ]; then
        printf '%s\n' "$build_cmd"
        return 0
    fi

    make -C out BR2_JLEVEL="$jobs"

    printf 'keel: build done, jobs=%s, images in out/images/\n' "$jobs"
}

# Run only when executed, not when sourced. A POSIX dot script can use
# return, so the subshell test succeeds only in that case.
if (return 0 2>/dev/null); then
    :
else
    keel_build_main "$@"
fi
