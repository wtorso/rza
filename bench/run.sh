#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/bench
mkdir --parents "$BUILD"
CC=${CC:-cc}
CFLAGS="-std=c23 -O2 -pedantic -Wall -Wextra -Werror -I refs -I ."
REPEATS=20

./rez3asm.exe docs/examples/shop.rza --emit-lib -o "$BUILD/shop.c"
./rez3asm.exe bench/fib_work.rza --emit-c -o "$BUILD/fib_rza.c"
$CC $CFLAGS "$BUILD/shop.c" examples/shop_host.c -o "$BUILD/rza_shop"
$CC $CFLAGS examples/shop_baseline.c -o "$BUILD/c_shop"
$CC $CFLAGS "$BUILD/fib_rza.c" -o "$BUILD/rza_fib"
$CC $CFLAGS bench/fib_work.c -o "$BUILD/c_fib"
rustc -O examples/shop.rs -o "$BUILD/rust_shop"
rustc -O bench/fib_work.rs -o "$BUILD/rust_fib"

"$BUILD/rza_shop" >"$BUILD/rza_shop.out"
"$BUILD/c_shop" >"$BUILD/c_shop.out"
"$BUILD/rust_shop" >"$BUILD/rust_shop.out"
diff docs/examples/shop.expected "$BUILD/rza_shop.out"
diff "$BUILD/rza_shop.out" "$BUILD/c_shop.out"
diff "$BUILD/rza_shop.out" "$BUILD/rust_shop.out"
"$BUILD/rza_fib" >"$BUILD/rza_fib.out"
"$BUILD/c_fib" >"$BUILD/c_fib.out"
"$BUILD/rust_fib" >"$BUILD/rust_fib.out"
diff "$BUILD/rza_fib.out" "$BUILD/c_fib.out"
diff "$BUILD/rza_fib.out" "$BUILD/rust_fib.out"

: >"$BUILD/results.txt"
measure() {
    local label=$1
    shift
    local start end sample total=0
    local -a samples sorted
    samples=()
    for _ in $(seq "$REPEATS"); do
        start=$(date +%s%N)
        "$@" >/dev/null
        end=$(date +%s%N)
        sample=$(( (end - start) / 1000000 ))
        samples+=("$sample")
        total=$((total + sample))
    done
    mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
    printf '%s samples_ms=%s\n' "$label" "${samples[*]}" >>"$BUILD/results.txt"
    printf '%s median_ms=%s min_ms=%s max_ms=%s total_ms=%d\n' \
        "$label" "${sorted[9]}" "${sorted[0]}" "${sorted[-1]}" "$total" \
        >>"$BUILD/results.txt"
}

measure transpile_shop_ms ./rez3asm.exe docs/examples/shop.rza --emit-lib \
    -o "$BUILD/shop.c"
measure compile_c_shop_ms $CC $CFLAGS examples/shop_baseline.c \
    -o "$BUILD/c_shop"
measure compile_rust_shop_ms rustc -O examples/shop.rs \
    -o "$BUILD/rust_shop"
measure transpile_fib_ms ./rez3asm.exe bench/fib_work.rza --emit-c \
    -o "$BUILD/fib_rza.c"
measure compile_c_fib_ms $CC $CFLAGS bench/fib_work.c \
    -o "$BUILD/c_fib"
measure compile_rust_fib_ms rustc -O bench/fib_work.rs \
    -o "$BUILD/rust_fib"
measure compile_rza_shop_generated_ms $CC $CFLAGS "$BUILD/shop.c" \
    examples/shop_host.c -o "$BUILD/rza_shop"
measure compile_rza_fib_generated_ms $CC $CFLAGS "$BUILD/fib_rza.c" \
    -o "$BUILD/rza_fib"
measure run_rza_shop_ms "$BUILD/rza_shop"
measure run_c_shop_ms "$BUILD/c_shop"
measure run_rust_shop_ms "$BUILD/rust_shop"
measure run_rza_fib_ms "$BUILD/rza_fib"
measure run_c_fib_ms "$BUILD/c_fib"
measure run_rust_fib_ms "$BUILD/rust_fib"

for artifact in shop.c fib_rza.c rza_shop c_shop rust_shop rza_fib c_fib rust_fib; do
    printf 'artifact_bytes %s %d\n' "$artifact" "$(wc -c <"$BUILD/$artifact")" \
        >>"$BUILD/results.txt"
done
printf 'outputs: shop and fib identical across RZA/C/Rust\n' >>"$BUILD/results.txt"
cat "$BUILD/results.txt"
