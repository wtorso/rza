#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ]; then
    echo "FATAL: bench/run.sh currently requires Linux and clock_gettime" >&2
    exit 2
fi
BUILD=${RZA_BENCH_BUILD:-build/bench}
CC=${CC:-cc}
RUSTC=${RUSTC:-rustc}
RUST_CC=${RUST_CC:-$CC}
CFLAGS="-std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I ."
LDFLAGS=${LDFLAGS:-}
if [ -z "${RZA_COMPILER:-}" ]; then
    RZA_COMPILER="./build/bin/rez3asm"
    if [ "${OS:-}" = "Windows_NT" ]; then RZA_COMPILER="./build/bin/rez3asm.exe"; fi
fi
export CC CFLAGS LDFLAGS RUSTC RUST_CC RZA_COMPILER
REPEATS=${RZA_BENCH_COMPILE_REPEATS:-20}
SAMPLES=${RZA_BENCH_SAMPLES:-11}
BATCH=${RZA_BENCH_BATCH:-256}
for value in "$REPEATS" "$SAMPLES" "$BATCH"; do
    case "$value" in
        ''|*[!0-9]*) echo "FATAL: repeat counts must be positive integers" >&2; exit 2 ;;
    esac
done
if ((REPEATS < 1 || REPEATS > 1000 || SAMPLES < 1 || SAMPLES > 101 ||
        BATCH < 1 || BATCH > 1000000)); then
    echo "FATAL: compile<=1000, samples<=101, batch<=1000000" >&2
    exit 2
fi
for tool in objdump awk date; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: $tool is required" >&2
        exit 2
    fi
done
mkdir --parents "$BUILD"
bash build_compiler.sh
bash bench/check.sh "$BUILD/check"

build_rza() {
    local name=$1 host=$2
    "$RZA_COMPILER" "bench/$name.rza" --emit-lib -o "$BUILD/$name.rza.c"
    $CC $CFLAGS $LDFLAGS "$BUILD/$name.rza.c" "bench/$host" \
        bench/runtime_host.c bench/timer.c -o "$BUILD/${name}_rza"
}

build_c() {
    local name=$1
    $CC $CFLAGS $LDFLAGS "bench/$name.c" bench/runtime_host.c bench/timer.c \
        -o "$BUILD/${name}_c"
}

build_rust() {
    local name=$1
    $RUSTC --edition=2021 -D warnings --crate-type=staticlib -O "bench/$name.rs" \
        -o "$BUILD/lib$name.a"
    $RUST_CC $CFLAGS $LDFLAGS bench/runtime_host.c bench/timer.c "$BUILD/lib$name.a" \
        -lpthread -ldl -lm -o "$BUILD/${name}_rust"
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
"$RZA_COMPILER" bench/calls.rza --emit-lib -o "$BUILD/calls.rza.c"
for variant in internal abi_direct abi_indirect; do
    $CC $CFLAGS $LDFLAGS -D"CALLS_${variant^^}" "$BUILD/calls.rza.c" \
        bench/rza_calls_host.c bench/runtime_host.c bench/timer.c \
        -o "$BUILD/calls_${variant}_rza"
done
for kind in single queue; do
    "$RZA_COMPILER" "bench/async_$kind.rza" --emit-lib -o "$BUILD/async_$kind.rza.c"
    $CC $CFLAGS $LDFLAGS -D"ASYNC_${kind^^}" "$BUILD/async_$kind.rza.c" \
        bench/rza_async_host.c bench/runtime_host.c bench/timer.c \
        -o "$BUILD/async_${kind}_rza"
done

RESULTS="$BUILD/results.txt"
: >"$RESULTS"
{
    printf 'date=%s\n' "$(date --iso-8601=seconds)"
    printf 'system=%s\n' "$(uname -a)"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | grep 'Model name:' || true
    fi
    printf 'cc=%s\n' "$CC"
    $CC --version | sed -n '1p'
    printf 'rust_link_cc=%s\n' "$RUST_CC"
    $RUST_CC --version | sed -n '1p'
    printf 'c3c=%s\n' "$(command -v c3c || true)"
    c3c --version
    $RUSTC --version
    printf 'flags=%s\n' "$CFLAGS"
    printf 'compile_repeats=%s runtime_samples=%s batch_steps=%s\n' \
        "$REPEATS" "$SAMPLES" "$BATCH"
    printf 'timer=clock_gettime(CLOCK_MONOTONIC), prepare outside, two batch warmups\n'
} >>"$RESULTS"

measure() {
    local label=$1
    shift
    local start end sample total=0
    local -a samples sorted
    samples=()
    for ((iteration = 0; iteration < REPEATS; iteration++)); do
        start=$(date +%s%N)
        "$@" >/dev/null
        end=$(date +%s%N)
        sample=$((end - start))
        samples+=("$sample")
        total=$((total + sample))
    done
    mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
    printf '%s samples_ns=%s\n' "$label" "${samples[*]}" >>"$RESULTS"
    printf '%s median_ns=%s min_ns=%s max_ns=%s total_ns=%s\n' \
        "$label" "${sorted[REPEATS / 2]}" "${sorted[0]}" \
        "${sorted[REPEATS - 1]}" "$total" >>"$RESULTS"
}

for name in crc32c crc32c_table table ring parser; do
    case "$name" in
        crc32c*) host=rza_crc_host.c ;;
        ring) host=rza_ring_host.c ;;
        parser) host=rza_parser_host.c ;;
        *) host=rza_table_host.c ;;
    esac
    measure "transpile_${name}_rza" "$RZA_COMPILER" "bench/$name.rza" \
        --emit-lib -o "$BUILD/$name.rza.c"
    measure "compile_${name}_c" bash -c \
        "$CC $CFLAGS $LDFLAGS bench/$name.c bench/runtime_host.c bench/timer.c \
            -o $BUILD/${name}_c"
    measure "compile_${name}_rust" bash -c \
        "$RUSTC --edition=2021 -D warnings --crate-type=staticlib -O bench/$name.rs \
            -o $BUILD/lib$name.a && $RUST_CC $CFLAGS $LDFLAGS bench/runtime_host.c \
            bench/timer.c $BUILD/lib$name.a -lpthread -ldl -lm -o $BUILD/${name}_rust"
    measure "backend_${name}_rza" $CC $CFLAGS $LDFLAGS "$BUILD/$name.rza.c" \
        "bench/$host" bench/runtime_host.c bench/timer.c \
        -o "$BUILD/${name}_rza"
    measure "pipeline_${name}_rza" bash -c \
        "\"$RZA_COMPILER\" bench/$name.rza --emit-lib -o $BUILD/$name.rza.c && \
            $CC $CFLAGS $LDFLAGS $BUILD/$name.rza.c bench/$host \
            bench/runtime_host.c bench/timer.c -o $BUILD/${name}_rza"
done
measure "transpile_calls_rza" "$RZA_COMPILER" bench/calls.rza \
    --emit-lib -o "$BUILD/calls.rza.c"
for variant in internal abi_direct abi_indirect; do
    measure "backend_calls_${variant}_rza" $CC $CFLAGS $LDFLAGS \
        -D"CALLS_${variant^^}" "$BUILD/calls.rza.c" bench/rza_calls_host.c \
        bench/runtime_host.c bench/timer.c -o "$BUILD/calls_${variant}_rza"
done
measure "pipeline_calls_internal_rza" bash -c \
    "\"$RZA_COMPILER\" bench/calls.rza --emit-lib -o $BUILD/calls.rza.c && \
        $CC $CFLAGS $LDFLAGS -DCALLS_INTERNAL $BUILD/calls.rza.c \
        bench/rza_calls_host.c bench/runtime_host.c bench/timer.c \
        -o $BUILD/calls_internal_rza"
for kind in single queue; do
    measure "transpile_async_${kind}_rza" "$RZA_COMPILER" "bench/async_$kind.rza" \
        --emit-lib -o "$BUILD/async_$kind.rza.c"
    measure "backend_async_${kind}_rza" $CC $CFLAGS $LDFLAGS -D"ASYNC_${kind^^}" \
        "$BUILD/async_$kind.rza.c" bench/rza_async_host.c bench/runtime_host.c \
        bench/timer.c -o "$BUILD/async_${kind}_rza"
    measure "pipeline_async_${kind}_rza" bash -c \
        "\"$RZA_COMPILER\" bench/async_$kind.rza --emit-lib \
            -o $BUILD/async_$kind.rza.c && $CC $CFLAGS $LDFLAGS \
            -DASYNC_${kind^^} $BUILD/async_$kind.rza.c bench/rza_async_host.c \
            bench/runtime_host.c bench/timer.c -o $BUILD/async_${kind}_rza"
done

measure_runtime() {
    local name=$1 median
    "$BUILD/$name" "$SAMPLES" "$BATCH" >"$BUILD/$name.runtime"
    printf 'runtime_%s ' "$name" >>"$RESULTS"
    tr '\n' ' ' <"$BUILD/$name.runtime" >>"$RESULTS"
    printf '\n' >>"$RESULTS"
    median=$(awk -F'[= ]' '/^median_ns=/{print $2}' "$BUILD/$name.runtime")
    local metric=$name
    if [ "$name" = crc32c_intrinsic_rust ]; then
        metric=crc32c_software_fallback_rust
        if grep --quiet 'backend=hardware_sse42' "$BUILD/$name.runtime"; then
            metric=crc32c_sse42_rust
        fi
    fi
    if [[ "$name" == crc32c* ]]; then
        awk -v ns="$median" -v batch="$BATCH" \
            'BEGIN { printf "runtime_%s_ns_per_byte=%.3f\n", "'"$metric"'", ns/(batch*4096) }' \
            >>"$RESULTS"
    elif [[ "$name" == async_* ]]; then
        awk -v ns="$median" -v batch="$BATCH" \
            'BEGIN { printf "runtime_%s_ns_per_task=%.3f\n", "'"$name"'", ns/(batch*1024) }' \
            >>"$RESULTS"
    else
        awk -v ns="$median" -v batch="$BATCH" \
            'BEGIN { printf "runtime_%s_ns_per_step=%.3f\n", "'"$name"'", ns/batch }' \
            >>"$RESULTS"
    fi
}

for name in crc32c_rza crc32c_flat_rza crc32c_table_rza crc32c_hw_rza \
        crc32c_hw_unroll_rza crc32c_c crc32c_table_c crc32c_rust crc32c_table_rust \
        crc32c_intrinsic_rust table_rza table_c table_rust ring_rza ring_c ring_rust \
        parser_rza parser_c parser_rust checked_arith_rza checked_arith_wrap_rza \
        calls_internal_rza calls_abi_direct_rza calls_abi_indirect_rza \
        async_single_rza async_queue_rza; do
    measure_runtime "$name"
done
for artifact in crc32c.rza.c crc32c_flat.rza.c crc32c_table.rza.c crc32c_hw.rza.c \
        crc32c_hw_unroll.rza.c table.rza.c ring.rza.c parser.rza.c checked_arith.rza.c \
        checked_arith_wrap.rza.c calls.rza.c async_single.rza.c async_queue.rza.c \
        crc32c_rza crc32c_flat_rza crc32c_table_rza crc32c_hw_rza crc32c_hw_unroll_rza \
        crc32c_c crc32c_table_c crc32c_rust crc32c_table_rust crc32c_intrinsic_rust \
        table_rza table_c table_rust ring_rza ring_c ring_rust parser_rza parser_c \
        parser_rust checked_arith_rza checked_arith_wrap_rza calls_internal_rza \
        calls_abi_direct_rza calls_abi_indirect_rza async_single_rza async_queue_rza; do
    printf 'artifact_bytes %s %s\n' "$artifact" "$(wc -c <"$BUILD/$artifact")" \
        >>"$RESULTS"
done
bash bench/inspect.sh "$BUILD" >>"$RESULTS"
printf 'outputs: correctness and repeated steps verified before timing\n' >>"$RESULTS"
cat "$RESULTS"
