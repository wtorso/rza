#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo "usage: bash bench/check.sh BUILD_DIR" >&2
    exit 2
fi
BUILD=$1
CC=${CC:-cc}
CFLAGS=${CFLAGS:--std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I .}
LDFLAGS=${LDFLAGS:-}
RUSTC=${RUSTC:-rustc}
RUST_CC=${RUST_CC:-$CC}
if [ -z "${RZA_COMPILER:-}" ]; then
    RZA_COMPILER="./build/bin/rez3asm"
    if [ "${OS:-}" = "Windows_NT" ]; then RZA_COMPILER="./build/bin/rez3asm.exe"; fi
fi
mkdir --parents "$BUILD"

build_rza() {
    local name=$1 host=$2
    "$RZA_COMPILER" "bench/$name.rza" --emit-lib -o "$BUILD/$name.c"
    $CC $CFLAGS $LDFLAGS "$BUILD/$name.c" "bench/$host" bench/bench_check.c \
        -o "$BUILD/${name}_rza"
}

build_c() {
    local name=$1
    $CC $CFLAGS $LDFLAGS "bench/$name.c" bench/bench_check.c \
        -o "$BUILD/${name}_c"
}

build_rust() {
    local name=$1
    $RUSTC --edition=2021 --crate-type=staticlib -D warnings -O "bench/$name.rs" \
        -o "$BUILD/lib$name.a"
    $RUST_CC $CFLAGS $LDFLAGS bench/bench_check.c "$BUILD/lib$name.a" \
        -lpthread -ldl -lm -o "$BUILD/${name}_rust"
}

check_output() {
    local name=$1 expected=$2
    "$BUILD/$name" >"$BUILD/$name.out"
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
build_rza checked_arith rza_checked_host.c
build_rza checked_arith_wrap rza_checked_host.c
"$RZA_COMPILER" bench/calls.rza --emit-lib -o "$BUILD/calls.c"
for variant in internal abi_direct abi_indirect; do
    $CC $CFLAGS $LDFLAGS -D"CALLS_${variant^^}" "$BUILD/calls.c" \
        bench/rza_calls_host.c bench/bench_check.c -o "$BUILD/calls_${variant}_rza"
done
for kind in single queue; do
    "$RZA_COMPILER" "bench/async_$kind.rza" --emit-lib -o "$BUILD/async_$kind.c"
    $CC $CFLAGS $LDFLAGS -D"ASYNC_${kind^^}" "$BUILD/async_$kind.c" \
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
for name in checked_arith_rza checked_arith_wrap_rza; do
    check_output "$name" checked_arith
done
for variant in internal abi_direct abi_indirect; do
    check_output "calls_${variant}_rza" calls
done
for kind in single queue; do
    check_output "async_${kind}_rza" async
done

# Changing only the key mask creates 1024 distinct requests. After 512 inserts
# every slot is occupied; all implementations must return zero, not a key difference.
sed -e '1i; Full-table variant: 1024 distinct keys; no free slot returns 0.' \
    -e 's/and %r1, %r1, 255/and %r1, %r1, 1023/' bench/table.rza \
    >"$BUILD/table_full.rza"
sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.c >"$BUILD/table_full.c"
sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.rs >"$BUILD/table_full.rs"
"$RZA_COMPILER" "$BUILD/table_full.rza" --emit-lib -o "$BUILD/table_full.rza.c"
$CC $CFLAGS $LDFLAGS "$BUILD/table_full.rza.c" bench/rza_table_host.c \
    bench/bench_check.c -o "$BUILD/table_full_rza"
$CC $CFLAGS $LDFLAGS "$BUILD/table_full.c" bench/bench_check.c \
    -o "$BUILD/table_full_c"
$RUSTC --edition=2021 -D warnings --crate-type=staticlib -O "$BUILD/table_full.rs" \
    -o "$BUILD/libtable_full.a"
$RUST_CC $CFLAGS $LDFLAGS bench/bench_check.c "$BUILD/libtable_full.a" \
    -lpthread -ldl -lm -o "$BUILD/table_full_rust"
for name in table_full_rza table_full_c table_full_rust; do
    check_output "$name" table_full
done

$CC $CFLAGS $LDFLAGS bench/crc32c.c bench/crc32c_vector.c \
    -o "$BUILD/crc32c_vector"
check_output crc32c_vector crc32c_vector
$CC $CFLAGS $LDFLAGS -DCRC32C_TABLE bench/crc32c_table.c bench/crc32c_vector.c \
    -o "$BUILD/crc32c_table_vector"
check_output crc32c_table_vector crc32c_vector
$RUSTC --edition=2021 --test -D warnings -O bench/workloads_test.rs \
    -o "$BUILD/workloads_test"
"$BUILD/workloads_test"
$CC $CFLAGS $LDFLAGS bench/timer.c bench/timer_test.c -o "$BUILD/timer_test"
"$BUILD/timer_test" >"$BUILD/timer_test.out"
grep --quiet '^result=42 backend=software ' "$BUILD/timer_test.out"
grep --quiet '^PASS timer warmup/batch/argument checks$' "$BUILD/timer_test.out"
echo "PASS crc32c/table workloads: all variants agree"
