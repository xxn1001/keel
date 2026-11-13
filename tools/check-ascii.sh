#!/bin/sh
# Fail if source files contain non-ASCII bytes.
# Documents may contain Chinese; source/config/scripts must be ASCII.
set -eu

roots=""
for d in src buildroot initrd image installer update rescue tools tests; do
    [ -d "$d" ] && roots="$roots $d"
done

if [ -z "$roots" ]; then
    echo "check-ascii: no source directories found"
    exit 0
fi

matches=$(find $roots -type f \
    \( -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' \
    -o -name '*.rs' -o -name '*.sh' -o -name '*.py' -o -name '*.go' \
    -o -name '*.conf' -o -name '*.service' -o -name '*.network' \
    -o -name 'Makefile' -o -name '*.mk' \) \
    -exec env LC_ALL=C grep -l '[^[:print:][:space:]]' {} + 2>/dev/null || true)

if [ -n "$matches" ]; then
    echo "non-ASCII source files:"
    echo "$matches"
    echo
    echo "$matches" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "--- $f"
        env LC_ALL=C grep -n '[^[:print:][:space:]]' "$f" || true
    done
    exit 1
fi

echo "check-ascii: ok"
