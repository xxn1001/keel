#!/bin/sh
# Validate a branch name: <type>/<slug>, lower-case ASCII, no F-xxx.
set -eu

branch=${1:-}
if [ -z "$branch" ]; then
    branch=$(git symbolic-ref --quiet --short HEAD || true)
fi

if [ -z "$branch" ]; then
    echo "check-branch-name: no branch name (detached HEAD?)" >&2
    exit 1
fi

case "$branch" in
    main)
        echo "check-branch-name: ok (main is protected)"
        exit 0
        ;;
    feat/*|fix/*|docs/*|test/*|ci/*|refactor/*|chore/*|build/*|perf/*|revert/*)
        ;;
    *)
        echo "check-branch-name: bad type: $branch" >&2
        echo "expected: feat|fix|docs|test|ci|refactor|chore|build|perf|revert/<slug>" >&2
        exit 1
        ;;
esac

slug=${branch#*/}
case "$slug" in
    ""|*[!a-z0-9.-]*|.*|*.|*..*)
        echo "check-branch-name: bad slug: $slug" >&2
        echo "use lower-case ASCII, digits, dot, hyphen; no leading/trailing dot" >&2
        exit 1
        ;;
esac

if [ "${#branch}" -gt 50 ]; then
    echo "check-branch-name: branch name longer than 50 chars: $branch" >&2
    exit 1
fi

echo "check-branch-name: ok: $branch"
