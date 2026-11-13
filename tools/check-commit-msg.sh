#!/bin/sh
# Validate one commit message file: Conventional Commits, lower-case subject.
set -eu

file=${1:-}
if [ -z "$file" ]; then
    echo "usage: check-commit-msg.sh <commit-msg-file>" >&2
    exit 2
fi

subject=$(sed -n '1p' "$file")

if [ "${#subject}" -gt 72 ]; then
    echo "check-commit-msg: subject longer than 72 chars" >&2
    exit 1
fi

case "$subject" in
    *.)
        echo "check-commit-msg: subject must not end with a dot" >&2
        exit 1
        ;;
esac

if ! printf '%s\n' "$subject" | grep -Eq \
    '^(feat|fix|docs|test|ci|refactor|chore|build|perf|revert)(\([a-z0-9-]+\))?: [a-z0-9]'; then
    echo "check-commit-msg: bad subject: $subject" >&2
    echo "expected: <type>(<scope>): <lower-case summary>" >&2
    exit 1
fi

echo "check-commit-msg: ok: $subject"
