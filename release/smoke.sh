#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo "usage: bash release/smoke.sh ARCHIVE" >&2
    exit 2
fi
archive=$1
test -f "$archive"
filename=${archive##*/}
package=${filename%.tar.gz}
version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' project.json)
case "$package" in
    "rza-$version-"*) ;;
    *) echo "FATAL: unexpected archive name: $filename" >&2; exit 2 ;;
esac
target=${package#"rza-$version-"}

mkdir --parents build
work=$(mktemp -d "$PWD/build/release-smoke.XXXXXX")
trap 'rm --recursive --force "$work"' EXIT
tar -xzf "$archive" -C "$work"
root="$work/$package"
test -d "$root"
test ! -e "$root/.git"
test ! -e "$root/build"
test ! -e "$root/docs"

compiler="$root/rez3asm"
executable="$work/hello"
if [ "${OS:-}" = "Windows_NT" ]; then
    compiler="$root/rez3asm.exe"
    executable="$work/hello.exe"
else
    test ! -e "$root/rez3asm.exe"
fi
test -x "$compiler"
test "$(sed -n 's/^RZA_DIRTY=//p' "$root/RELEASE")" != ""
dirty=$(sed -n 's/^RZA_DIRTY=//p' "$root/RELEASE")
if [ "${RZA_RELEASE_REQUIRE_CLEAN:-0}" = 1 ] && [ "$dirty" != 0 ]; then
    echo "FATAL: dirty archive is not a clean release" >&2
    exit 1
fi
printf '%s\n' "RZA_VERSION=$version" "RZA_COMMIT=$(git rev-parse HEAD)" \
    "RZA_TARGET=$target" "C3_VERSION=0.8.5_1" "RZA_DIRTY=$dirty" \
    >"$work/RELEASE.expected"
diff --unified "$work/RELEASE.expected" "$root/RELEASE"

test "$("$compiler" --version)" = "rez3asm $version"
"$compiler" --help >"$work/help.out" 2>"$work/help.err"
diff --unified "$root/tests/cli_help.expected" "$work/help.out"
test ! -s "$work/help.err"
"$compiler" "$root/examples/hello.rza" --emit-c -o "$work/hello.c"
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror \
    -I "$root/refs" "$work/hello.c" -o "$executable"
test "$("$executable")" = 41
RZA_COMPILER="$compiler" bash "$root/tests/install_smoke.sh"
printf 'RELEASE_SMOKE OK package=%s output=41\n' "$package"
