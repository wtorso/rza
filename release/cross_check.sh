#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
    echo "FATAL: cross-checkout verification requires a clean source" >&2
    exit 2
fi
export PATH="$PWD/build/toolchain/c3:$PATH"
work=$(mktemp -d "$PWD/build/release-cross.XXXXXX")
cleanup() {
    if [ -d "$work/source" ]; then git worktree remove "$work/source"; fi
    rm --recursive --force "$work"
}
trap cleanup EXIT

git worktree add --detach "$work/source" HEAD
first=$(RZA_RELEASE_OUT="$work/first" bash release/package.sh)
second=$(cd "$work/source" && RZA_RELEASE_OUT="$work/second" bash release/package.sh)
test -f "$first"
test -f "$second"
if ! cmp --silent "$first" "$second"; then
    echo "FATAL: archives differ across checkout paths" >&2
    sha256sum "$first" "$second" >&2
    exit 1
fi
sha256sum "$first"
printf 'RELEASE_CROSS_CHECK OK paths=independent byte-identical\n'
