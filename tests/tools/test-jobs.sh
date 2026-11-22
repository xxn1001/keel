#!/bin/sh
# Test the host-sized job count used by tools/build.sh.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck source=/dev/null
. "$repo_dir/tools/build.sh"

# expected = max(1, min(nproc, ram_gib - 2, 16))
status=0
while read -r nproc ram_gib expected; do
    [ -n "$nproc" ] || continue
    actual=$(keel_jobs "$nproc" "$ram_gib")
    if [ "$actual" -lt 1 ]; then
        printf 'FAIL: keel_jobs %s %s -> %s (below 1)\n' "$nproc" "$ram_gib" "$actual"
        status=1
    elif [ "$actual" -ne "$expected" ]; then
        printf 'FAIL: keel_jobs %s %s -> %s (expected %s)\n' \
            "$nproc" "$ram_gib" "$actual" "$expected"
        status=1
    else
        printf 'PASS: keel_jobs %s %s -> %s\n' "$nproc" "$ram_gib" "$actual"
    fi
done <<'EOF'
1 1 1
4 4 2
8 16 8
32 14 12
32 128 16
0 14 1
EOF

if [ "$status" -ne 0 ]; then
    echo "test-jobs: failed"
    exit "$status"
fi

echo "test-jobs: ok"
