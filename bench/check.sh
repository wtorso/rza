#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo "usage: bash bench/check.sh BUILD_DIR" >&2
    exit 2
fi
BUILD=$1
CC=${CC:-cc}
CFLAGS=${CFLAGS:--std=c23 -O2 -pedantic -Wall -Wextra -Werror -I refs -I .}
LDFLAGS=${LDFLAGS:-}
RUSTC=${RUSTC:-rustc}
mkdir --parents "$BUILD"

build_rza() {
    local name=$1 host=$2
    ./rez3asm.exe "bench/$name.rza" --emit-lib -o "$BUILD/$name.c"
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
    $CC $CFLAGS $LDFLAGS bench/bench_check.c "$BUILD/lib$name.a" \
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
build_c crc32c
build_rust crc32c
build_rust crc32c_intrinsic
build_rza table rza_table_host.c
build_c table
build_rust table

for name in crc32c_rza crc32c_flat_rza crc32c_c crc32c_rust \
        crc32c_intrinsic_rust; do
    check_output "$name" crc32c
done
for name in table_rza table_c table_rust; do
    check_output "$name" table
done

# Changing only the key mask creates 1024 distinct requests. After 512 inserts
# every slot is occupied; all implementations must return zero, not a key difference.
sed -e '1i; Full-table variant: 1024 distinct keys; no free slot returns 0.' \
    -e 's/and %r1, %r1, 255/and %r1, %r1, 1023/' bench/table.rza \
    >"$BUILD/table_full.rza"
sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.c >"$BUILD/table_full.c"
sed 's/) & 255) + 1/) \& 1023) + 1/' bench/table.rs >"$BUILD/table_full.rs"
./rez3asm.exe "$BUILD/table_full.rza" --emit-lib -o "$BUILD/table_full.rza.c"
$CC $CFLAGS $LDFLAGS "$BUILD/table_full.rza.c" bench/rza_table_host.c \
    bench/bench_check.c -o "$BUILD/table_full_rza"
$CC $CFLAGS $LDFLAGS "$BUILD/table_full.c" bench/bench_check.c \
    -o "$BUILD/table_full_c"
$RUSTC --edition=2021 -D warnings --crate-type=staticlib -O "$BUILD/table_full.rs" \
    -o "$BUILD/libtable_full.a"
$CC $CFLAGS $LDFLAGS bench/bench_check.c "$BUILD/libtable_full.a" \
    -lpthread -ldl -lm -o "$BUILD/table_full_rust"
for name in table_full_rza table_full_c table_full_rust; do
    check_output "$name" table_full
done

$CC $CFLAGS $LDFLAGS bench/crc32c.c bench/crc32c_vector.c \
    -o "$BUILD/crc32c_vector"
check_output crc32c_vector crc32c_vector
$RUSTC --edition=2021 --test -O bench/workloads_test.rs -o "$BUILD/workloads_test"
"$BUILD/workloads_test"
$CC $CFLAGS $LDFLAGS bench/timer.c bench/timer_test.c -o "$BUILD/timer_test"
"$BUILD/timer_test" >"$BUILD/timer_test.out"
grep --quiet '^result=42 backend=software ' "$BUILD/timer_test.out"
grep --quiet '^PASS timer warmup/batch/argument checks$' "$BUILD/timer_test.out"
echo "PASS crc32c/table workloads: all variants agree"
