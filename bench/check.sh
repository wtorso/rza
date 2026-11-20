#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo "usage: bash bench/check.sh BUILD_DIR" >&2
    exit 2
fi
BUILD=$1
. ./cc.sh
rza_cc_init release include/rza . || exit 2
RUSTC=${RUSTC:-rustc}
RUST_CC=${RUST_CC:-$CC}
RUSTC_LINKER_ARGS=()
RUST_LIBS="-lpthread -ldl -lm"
RUST_LIB_EXT=a
if [ "${OS:-}" = "Windows_NT" ]; then
    RUST_LIBS="ws2_32.lib userenv.lib bcrypt.lib ntdll.lib synchronization.lib"
    RUST_LIB_EXT=lib
    if rza_cc_is_msvc; then
        rust_linker="${VCToolsInstallDir:-}/bin/Hostx64/x64/link.exe"
        if [ ! -f "$rust_linker" ]; then
            echo "FATAL: MSVC benchmarks require an x64 Native Tools environment" >&2
            exit 2
        fi
        RUSTC_LINKER_ARGS=(-C "linker=$(cygpath -m "$rust_linker")")
    fi
fi
if [ -z "${RZA_COMPILER:-}" ]; then
    RZA_COMPILER="./build/bin/rez3asm"
    if [ "${OS:-}" = "Windows_NT" ]; then RZA_COMPILER="./build/bin/rez3asm.exe"; fi
fi
mkdir --parents "$BUILD"

build_rza() {
    local name=$1 host=$2
    "$RZA_COMPILER" "bench/$name.rza" --emit-lib -o "$BUILD/$name.c"
    rza_cc "$BUILD/$name.c" "bench/$host" bench/bench_check.c \
        -o "$BUILD/${name}_rza"
}

build_c() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY ${1}_c native C comparison"
        return
    fi
    local name=$1
    rza_cc "bench/$name.c" bench/bench_check.c -o "$BUILD/${name}_c"
}

link_rust() {
    local flag flags=""
    for flag in $CFLAGS; do
        if [ "$flag" != "/TC" ]; then flags+="${flags:+ }$flag"; fi
    done
    CFLAGS="$flags" CC="$RUST_CC" bash ./cc.sh "$@"
}

build_rust() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY ${1}_rust native Rust comparison"
        return
    fi
    local name=$1
    $RUSTC "${RUSTC_LINKER_ARGS[@]}" --edition=2021 --crate-type=staticlib \
        -D warnings -O "bench/$name.rs" -o "$BUILD/lib$name.$RUST_LIB_EXT"
    link_rust bench/bench_check.c "$BUILD/lib$name.$RUST_LIB_EXT" \
        $RUST_LIBS -o "$BUILD/${name}_rust"
}

check_output() {
    local name=$1 expected=$2
    case "$name" in
        *_c|*_rust|*_c_[0-9]|*_rust_[0-9]|crc32c_vector|crc32c_table_vector)
            if [ -n "${RZA_TARGET_ARCH:-}" ]; then
                echo "HOST_ONLY $name native comparison"
                return
            fi
            ;;
    esac
    rza_run "$BUILD/$name" >"$BUILD/$name.out"
    diff --unified "bench/$expected.expected" "$BUILD/$name.out"
    echo "PASS $name"
}

build_rza crc32c rza_crc_host.c
build_rza crc32c_flat rza_crc_host.c
build_rza crc32c_table rza_crc_host.c
build_rza crc32c_hw rza_crc32c_host.c
build_rza crc32c_hw_unroll rza_crc32c_host.c
build_c crc32c
build_c crc32c_table
build_rust crc32c
build_rust crc32c_table
build_rust crc32c_intrinsic
build_rza table rza_table_host.c
build_c table
build_rust table
build_rza ring rza_ring_host.c
build_c ring
build_rust ring
build_rza parser rza_parser_host.c
build_c parser
build_rust parser
if ! grep --quiet '^[[:space:]]*view payload_m, input_m,' bench/protocol.rza; then
    echo "FATAL: protocol must construct a bounded payload view" >&2
    exit 1
fi
if grep --quiet 'scratch' bench/protocol.rza; then
    echo "FATAL: protocol retains a scratch payload copy" >&2
    exit 1
fi
build_rza protocol rza_protocol_host.c
build_c protocol
build_rust protocol
build_rza checked_arith rza_checked_host.c
build_rza checked_arith_wrap rza_checked_host.c
"$RZA_COMPILER" bench/calls.rza --emit-lib -o "$BUILD/calls.c"
for variant in internal abi_direct abi_indirect; do
    rza_cc -D"CALLS_${variant^^}" "$BUILD/calls.c" \
        bench/rza_calls_host.c bench/bench_check.c -o "$BUILD/calls_${variant}_rza"
done
for kind in single queue; do
    "$RZA_COMPILER" "bench/async_$kind.rza" --emit-lib -o "$BUILD/async_$kind.c"
    rza_cc -D"ASYNC_${kind^^}" "$BUILD/async_$kind.c" \
        bench/rza_async_host.c bench/bench_check.c -o "$BUILD/async_${kind}_rza"
done

for name in crc32c_rza crc32c_flat_rza crc32c_table_rza crc32c_hw_rza \
        crc32c_hw_unroll_rza crc32c_c crc32c_table_c crc32c_rust crc32c_table_rust \
        crc32c_intrinsic_rust; do
    check_output "$name" crc32c
done
for name in table_rza table_c table_rust; do
    check_output "$name" table
done
for name in ring_rza ring_c ring_rust; do
    check_output "$name" ring
done
for name in parser_rza parser_c parser_rust; do
    check_output "$name" parser
done
for name in protocol_rza protocol_c protocol_rust; do
    check_output "$name" protocol
done
for name in checked_arith_rza checked_arith_wrap_rza; do
    check_output "$name" checked_arith
done
for variant in internal abi_direct abi_indirect; do
    check_output "calls_${variant}_rza" calls
done
for kind in single queue; do
    check_output "async_${kind}_rza" async
done

for variant in 1 2 3; do
    case "$variant" in
        1) expected=protocol_quota ;;
        2) expected=protocol_truncated ;;
        3) expected=protocol_length_attack ;;
    esac
    rza_cc -DPROTOCOL_VARIANT="$variant" "$BUILD/protocol.c" \
        bench/rza_protocol_host.c bench/bench_check.c -o "$BUILD/protocol_rza_$variant"
    if [ -z "${RZA_TARGET_ARCH:-}" ]; then
        rza_cc -DPROTOCOL_VARIANT="$variant" bench/protocol.c \
            bench/bench_check.c -o "$BUILD/protocol_c_$variant"
        sed "s/^const VARIANT: u8 = 0;/const VARIANT: u8 = $variant;/" \
            bench/protocol.rs >"$BUILD/protocol_$variant.rs"
        $RUSTC "${RUSTC_LINKER_ARGS[@]}" --edition=2021 --crate-type=staticlib -D warnings -O \
            "$BUILD/protocol_$variant.rs" -o "$BUILD/libprotocol_$variant.$RUST_LIB_EXT"
        link_rust bench/bench_check.c "$BUILD/libprotocol_$variant.$RUST_LIB_EXT" \
            $RUST_LIBS -o "$BUILD/protocol_rust_$variant"
    fi
    for name in protocol_rza protocol_c protocol_rust; do
        check_output "${name}_$variant" "$expected"
    done
done

# Changing only the key mask creates 1024 distinct requests. After 512 inserts
# every slot is occupied; all implementations must return zero, not a key difference.
sed -e '1i; Full-table variant: 1024 distinct keys; no free slot returns 0.' \
    -e 's/and %r1, %r1, 255/and %r1, %r1, 1023/' bench/table.rza \
    >"$BUILD/table_full.rza"
"$RZA_COMPILER" "$BUILD/table_full.rza" --emit-lib -o "$BUILD/table_full.rza.c"
rza_cc "$BUILD/table_full.rza.c" bench/rza_table_host.c \
    bench/bench_check.c -o "$BUILD/table_full_rza"
if [ -z "${RZA_TARGET_ARCH:-}" ]; then
    sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.c >"$BUILD/table_full.c"
    sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.rs >"$BUILD/table_full.rs"
    rza_cc "$BUILD/table_full.c" bench/bench_check.c \
        -o "$BUILD/table_full_c"
    $RUSTC "${RUSTC_LINKER_ARGS[@]}" --edition=2021 -D warnings --crate-type=staticlib \
        -O "$BUILD/table_full.rs" -o "$BUILD/libtable_full.$RUST_LIB_EXT"
    link_rust bench/bench_check.c "$BUILD/libtable_full.$RUST_LIB_EXT" \
        $RUST_LIBS -o "$BUILD/table_full_rust"
fi
for name in table_full_rza table_full_c table_full_rust; do
    check_output "$name" table_full
done

if [ -z "${RZA_TARGET_ARCH:-}" ]; then
    rza_cc bench/crc32c.c bench/crc32c_vector.c \
        -o "$BUILD/crc32c_vector"
    check_output crc32c_vector crc32c_vector
    rza_cc -DCRC32C_TABLE bench/crc32c_table.c bench/crc32c_vector.c \
        -o "$BUILD/crc32c_table_vector"
    check_output crc32c_table_vector crc32c_vector
    $RUSTC "${RUSTC_LINKER_ARGS[@]}" --edition=2021 --test -D warnings -O \
        bench/workloads_test.rs -o "$BUILD/workloads_test"
    "$BUILD/workloads_test"
    rza_cc bench/timer.c bench/timer_test.c -o "$BUILD/timer_test"
    "$BUILD/timer_test" >"$BUILD/timer_test.out"
    grep --quiet '^result=42 backend=software ' "$BUILD/timer_test.out"
    grep --quiet '^PASS timer warmup/batch/argument checks$' "$BUILD/timer_test.out"
    echo "PASS crc32c/table workloads: all variants agree"
else
    echo "HOST_ONLY native C/Rust comparisons, vector drivers and timing"
    echo "PASS RZA target workloads: all applicable variants agree"
fi
