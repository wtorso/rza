#!/usr/bin/env bash
set -o nounset
cd "$(dirname "$0")/.."

BUILD=build/bench
mkdir --parents "$BUILD"
CC=${CC:-cc}
CFLAGS="-std=c23 -O2 -pedantic -Wall -Wextra -Werror -I refs -I ."
REPEATS=20

measure() {
    local label=$1
    shift
    local start end
    start=$(date +%s%N)
    for _ in $(seq "$REPEATS"); do "$@" >/dev/null; done
    end=$(date +%s%N)
    printf '%s %d\n' "$label" $(( (end - start) / 1000000 ))
}

: >"$BUILD/results.txt"
measure transpile_shop_ms ./rez3asm.exe docs/examples/shop.rza --emit-lib \
    -o "$BUILD/shop.c" >>"$BUILD/results.txt"
measure compile_c_shop_ms $CC $CFLAGS examples/shop_baseline.c \
    -o "$BUILD/c_shop" >>"$BUILD/results.txt"
measure compile_rust_shop_ms rustc -O examples/shop.rs \
    -o "$BUILD/rust_shop" >>"$BUILD/results.txt"
$CC $CFLAGS "$BUILD/shop.c" examples/shop_host.c -o "$BUILD/rza_shop"
measure transpile_fib_ms ./rez3asm.exe bench/fib_work.rza --emit-c \
    -o "$BUILD/fib_rza.c" >>"$BUILD/results.txt"
measure compile_c_fib_ms $CC $CFLAGS bench/fib_work.c \
    -o "$BUILD/c_fib" >>"$BUILD/results.txt"
measure compile_rust_fib_ms rustc -O bench/fib_work.rs \
    -o "$BUILD/rust_fib" >>"$BUILD/results.txt"
$CC $CFLAGS "$BUILD/fib_rza.c" -o "$BUILD/rza_fib"

measure run_rza_shop_ms "$BUILD/rza_shop" >>"$BUILD/results.txt"
measure run_c_shop_ms "$BUILD/c_shop" >>"$BUILD/results.txt"
measure run_rust_shop_ms "$BUILD/rust_shop" >>"$BUILD/results.txt"
measure run_rza_fib_ms "$BUILD/rza_fib" >>"$BUILD/results.txt"
measure run_c_fib_ms "$BUILD/c_fib" >>"$BUILD/results.txt"
measure run_rust_fib_ms "$BUILD/rust_fib" >>"$BUILD/results.txt"

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
printf 'outputs: shop and fib identical across RZA/C/Rust\n' >>"$BUILD/results.txt"
cat "$BUILD/results.txt"
