#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=${1:-build/bench}
CC=${CC:-cc}
ASM="$BUILD/asm"
mkdir --parents "$ASM"
if ! command -v objdump >/dev/null 2>&1; then
    echo "FATAL: objdump is required for assembly inspection" >&2
    exit 2
fi

dump() {
    local binary=$1 symbol=$2
    objdump --disassemble="$symbol" "$BUILD/$binary" >"$ASM/$binary.$symbol.asm"
    if ! grep --quiet "<$symbol>:" "$ASM/$binary.$symbol.asm"; then
        echo "FATAL: $symbol is absent from $binary" >&2
        exit 1
    fi
}

dump crc32c_rza rza_checksum
dump crc32c_flat_rza rza_checksum
dump crc32c_c crc32c_software
dump crc32c_rust crc32c_software
dump crc32c_intrinsic_rust workload_step
objdump -d "$BUILD/crc32c_intrinsic_rust" >"$ASM/crc32c_intrinsic_rust.all.asm"
backend=unrecorded
if [ -f "$BUILD/crc32c_intrinsic_rust.runtime" ]; then
    backend=$(sed -n 's/.*backend=\([^ ]*\).*/\1/p' \
        "$BUILD/crc32c_intrinsic_rust.runtime")
fi
if [ -z "$backend" ]; then backend=unrecorded; fi
case "$backend:$(uname -m)" in
    hardware_sse42:x86_64|hardware_sse42:amd64|unrecorded:x86_64|unrecorded:amd64)
        if ! grep --extended-regexp --quiet 'crc32[qbl]?[[:space:]]' \
                "$ASM/crc32c_intrinsic_rust.all.asm"; then
            echo "FATAL: hardware CRC instruction is absent" >&2
            exit 1
        fi
        echo "PASS: backend=$backend; hardware CRC instruction is present"
        ;;
    software:*)
        echo "NOTE: runtime backend=software; no hardware timing is claimed"
        ;;
    unrecorded:*)
        echo "NOTE: non-x86 fallback; x86 instruction assertion is skipped"
        ;;
    *)
        echo "FATAL: inconsistent backend=$backend arch=$(uname -m)" >&2
        exit 1
        ;;
esac
dump table_rza rza_table
dump table_c table_step
dump table_rust table_step

$CC -std=c23 -O2 -I refs -I . -c bench/safety/null_check.c -o "$ASM/null_default.o"
$CC -std=c23 -O2 -fno-delete-null-pointer-checks -I refs -I . \
    -c bench/safety/null_check.c -o "$ASM/null_hardened.o"
objdump --disassemble=tun_poll_guard "$ASM/null_default.o" >"$ASM/null_default.asm"
objdump --disassemble=tun_poll_guard "$ASM/null_hardened.o" >"$ASM/null_hardened.asm"
if cmp --silent \
        <(sed -n 's/^ *[[:xdigit:]][[:xdigit:]]*:[[:space:]]*//p' \
            "$ASM/null_default.asm") \
        <(sed -n 's/^ *[[:xdigit:]][[:xdigit:]]*:[[:space:]]*//p' \
            "$ASM/null_hardened.asm"); then
    echo "NOTE: null-check outputs are identical for this compiler; see source and flags"
else
    echo "PASS: null-check optimizer comparison is recorded"
fi
echo "Assembly and intrinsic checks: $ASM"
