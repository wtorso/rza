#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. ./cc.sh

PREFIX=${PREFIX:-/usr/local}
mkdir --parents build
work=$(mktemp -d build/install-smoke.XXXXXX)
trap 'rm --recursive --force "$work"' EXIT
stage="$work/stage"
mkdir --parents "$stage"

compiler_name="rez3asm"
executable_name="hello"
if [ "${OS:-}" = "Windows_NT" ]; then
    compiler_name="rez3asm.exe"
    executable_name="hello.exe"
fi

DESTDIR="$stage" PREFIX="$PREFIX" RZA_COMPILER="${RZA_COMPILER:-}" \
    bash install.sh >"$work/install.log" 2>&1
installed="$stage$PREFIX/bin/$compiler_name"
include_dir="$stage$PREFIX/include/rza"
test -x "$installed"
test -f "$include_dir/rez3.h"
test -f "$include_dir/rez3ext.h"
test -f "$stage$PREFIX/share/doc/rza/LICENSE"

version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' project.json)
test "$("$installed" --version)" = "rez3asm $version"
"$installed" --help >"$work/help.out" 2>"$work/help.err"
diff --unified tests/cli_help.expected "$work/help.out"
test ! -s "$work/help.err"

"$installed" examples/hello.rza --emit-c -o "$work/hello.c"
CFLAGS=""
LDFLAGS=""
rza_cc_init release
rza_cc -I "$include_dir" "$work/hello.c" -o "$work/$executable_name"
test "$("$work/$executable_name")" = 41
printf 'INSTALL_SMOKE OK version=%s output=41\n' "$version"
