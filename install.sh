#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
case "$PREFIX" in
    /*) ;;
    *) echo "FATAL: PREFIX must be an absolute path" >&2; exit 2 ;;
esac
if ! command -v install >/dev/null 2>&1; then
    echo "FATAL: install is required" >&2
    exit 2
fi

compiler_name="rez3asm"
if [ "${OS:-}" = "Windows_NT" ]; then compiler_name="rez3asm.exe"; fi
if [ -n "${RZA_COMPILER:-}" ]; then
    if [ ! -f "$RZA_COMPILER" ]; then
        echo "FATAL: RZA_COMPILER is not a file: $RZA_COMPILER" >&2
        exit 2
    fi
else
    bash build_compiler.sh
    RZA_COMPILER="./build/bin/$compiler_name"
fi

install -d "${DESTDIR}${PREFIX}/bin" \
    "${DESTDIR}${PREFIX}/include/rza" \
    "${DESTDIR}${PREFIX}/share/doc/rza"
install -m 0755 "$RZA_COMPILER" "${DESTDIR}${PREFIX}/bin/$compiler_name"
install -m 0644 include/rza/rez3.h include/rza/rez3ext.h \
    "${DESTDIR}${PREFIX}/include/rza"
install -m 0644 LICENSE "${DESTDIR}${PREFIX}/share/doc/rza/LICENSE"
printf 'RZA installed in %s\n' "${DESTDIR}${PREFIX}"
