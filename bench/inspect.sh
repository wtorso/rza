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
dump crc32c_table_rza rza_checksum
dump crc32c_table_c crc32c_table
dump crc32c_table_rust crc32c_table
dump crc32c_hw_rza rza_checksum
objdump -d "$BUILD/crc32c_hw_rza" >"$ASM/crc32c_hw_rza.all.asm"
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
rza_backend=unrecorded
if [ -f "$BUILD/crc32c_hw_rza.runtime" ]; then
    rza_backend=$(sed -n 's/.*backend=\([^ ]*\).*/\1/p' \
        "$BUILD/crc32c_hw_rza.runtime")
fi
if [ -z "$rza_backend" ]; then rza_backend=unrecorded; fi
case "$rza_backend:$(uname -m)" in
    hardware_sse42:x86_64|hardware_sse42:amd64)
        if ! grep --extended-regexp --quiet 'crc32[qbl]?[[:space:]]' \
                "$ASM/crc32c_hw_rza.all.asm"; then
            echo "FATAL: RZA hardware CRC instruction is absent" >&2
            exit 1
        fi
        dump crc32c_hw_unroll_rza rza_checksum_crc0_sse42
        unrolled=$(awk '/crc32[qbl]?[[:space:]]/ { count++ } END { print count + 0 }' \
            "$ASM/crc32c_hw_unroll_rza.rza_checksum_crc0_sse42.asm")
        if [ "$unrolled" -ne 8 ]; then
            echo "FATAL: unrolled RZA CRC has $unrolled instructions, want 8" >&2
            exit 1
        fi
        echo "PASS: RZA backend=hardware_sse42; crc32 instruction is present"
        echo "PASS: RZA hardware CRC has eight unrolled words"
        ;;
    software:*|unrecorded:*)
        echo "NOTE: RZA CRC runtime backend=$rza_backend"
        ;;
    *)
        echo "FATAL: inconsistent RZA backend=$rza_backend" >&2
        exit 1
        ;;
esac
dump table_rza rza_table
dump table_c table_step
dump table_rust table_step
dump ring_rza rza_ring
dump ring_c ring_step
dump ring_rust ring_step
dump parser_rza rza_parse
dump parser_c parse
dump parser_rust parse
dump checked_arith_rza rza_workload
dump checked_arith_wrap_rza rza_workload
case "$(uname -m)" in
    x86_64|amd64)
        if ! grep --extended-regexp --quiet '[[:space:]]jo[[:space:]]' \
                "$ASM/checked_arith_rza.rza_workload.asm"; then
            echo "FATAL: checked arithmetic has no overflow branch" >&2
            exit 1
        fi
        if grep --extended-regexp --quiet '[[:space:]]jo[[:space:]]' \
                "$ASM/checked_arith_wrap_rza.rza_workload.asm"; then
            echo "FATAL: wrapping arithmetic unexpectedly uses overflow branches" >&2
            exit 1
        fi
        echo "PASS: checked arithmetic uses jo; wrapping path does not"
        ;;
esac

$CC -std=c23 -O2 -I include/rza -I . -c bench/safety/null_check.c -o "$ASM/null_default.o"
$CC -std=c23 -O2 -fno-delete-null-pointer-checks -I include/rza -I . \
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
