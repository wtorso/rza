#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

work="build/release-verify"
rm --recursive --force "$work"
mkdir --parents "$work"
first=$(RZA_RELEASE_OUT="$PWD/$work/first" bash release/package.sh)
second=$(RZA_RELEASE_OUT="$PWD/$work/second" bash release/package.sh)
test -f "$first"
test -f "$second"
if ! cmp --silent "$first" "$second"; then
    echo "FATAL: release archives differ" >&2
    sha256sum "$first" "$second" >&2
    exit 1
fi
RZA_RELEASE_REQUIRE_CLEAN="${RZA_RELEASE_REQUIRE_CLEAN:-0}" \
    bash release/smoke.sh "$first"
sha256sum "$first"
printf 'RELEASE_VERIFY OK reproducible=byte-identical\n'
