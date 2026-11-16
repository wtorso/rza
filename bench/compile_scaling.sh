#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Linux ]; then
    echo "FATAL: compile_scaling.sh requires Linux and nanosecond date" >&2
    exit 2
fi
BUILD=${RZA_SCALING_BUILD:-build/compile-scaling}
CC=${CC:-cc}
CFLAGS=${CFLAGS:--std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I .}
REPEATS=${RZA_SCALING_REPEATS:-7}
BACKEND_REPEATS=${RZA_SCALING_BACKEND_REPEATS:-3}
BACKEND=${RZA_SCALING_BACKEND:-1}
COUNTS=${RZA_SCALING_COUNTS:-64 128 256 512 1024}
RZA_COMPILER=${RZA_COMPILER:-./build/bin/rez3asm}

for value in "$REPEATS" "$BACKEND_REPEATS"; do
    case "$value" in
        ''|*[!0-9]*) echo "FATAL: repeat counts must be positive integers" >&2; exit 2 ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 100 ]; then
        echo "FATAL: repeat counts must be within 1..100" >&2
        exit 2
    fi
done
case "$BACKEND" in
    0|1) ;;
    *) echo "FATAL: RZA_SCALING_BACKEND must be 0 or 1" >&2; exit 2 ;;
esac
for count in $COUNTS; do
    case "$count" in
        ''|*[!0-9]*) echo "FATAL: sizes must be positive integers" >&2; exit 2 ;;
    esac
    if [ "$count" -lt 1 ] || [ "$count" -gt 1024 ]; then
        echo "FATAL: sizes must be within 1..1024" >&2
        exit 2
    fi
done
mkdir --parents "$BUILD"
bash build_compiler.sh

generate_procs() {
    local output=$1 count=$2
    awk -v count="$count" '
        BEGIN {
            print "res state, field, 8"
            print "med state_m, state, field"
            for (i = 0; i < count; i++) {
                printf "proc work%d:\n", i
                if (i > 0) printf "    call work%d\n", i - 1
                print "    load %r0, [state_m + 0]"
                print "    add %r0, %r0, 1"
                print "    store [state_m + 0], %r0"
                print "    ret"
            }
            print "ret"
        }
    ' >"$output"
}

generate_async() {
    local output=$1 count=$2
    awk -v count="$count" '
        BEGIN {
            print "res state, field, 8"
            print "med state_m, state, field"
            for (i = 0; i < count; i++) {
                printf "acasc task%d: state_m -> out%d\n", i, i
                print "    load %r0, [state_m + 0]"
                print "endc"
                printf "med out%d_m, out%d, field\n", i, i
            }
            print "await %r0"
            print "ret"
        }
    ' >"$output"
}

measure() {
    local label=$1 repeats=$2
    shift 2
    local start end sample
    local -a samples sorted
    samples=()
    for ((iteration = 0; iteration < repeats; iteration++)); do
        start=$(date +%s%N)
        "$@" >/dev/null
        end=$(date +%s%N)
        sample=$((end - start))
        samples+=("$sample")
    done
    mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
    printf '%s samples_ns=%s\n' "$label" "${samples[*]}" >>"$RESULTS"
    printf '%s median_ns=%d min_ns=%d max_ns=%d\n' \
        "$label" "${sorted[repeats / 2]}" "${sorted[0]}" "${sorted[repeats - 1]}" \
        >>"$RESULTS"
}

RESULTS="$BUILD/results.txt"
: >"$RESULTS"
{
    printf 'date=%s\n' "$(date --iso-8601=seconds)"
    printf 'system=%s\n' "$(uname -a)"
    printf 'cc=%s\n' "$CC"
    $CC --version | sed -n '1p'
    printf 'repeats=%s backend_repeats=%s backend=%s counts=%s\n' \
        "$REPEATS" "$BACKEND_REPEATS" "$BACKEND" "$COUNTS"
} >>"$RESULTS"

for shape in procs async; do
    for count in $COUNTS; do
        source="$BUILD/${shape}_$count.rza"
        generated="$BUILD/${shape}_$count.c"
        if [ "$shape" = procs ]; then
            generate_procs "$source" "$count"
        else
            generate_async "$source" "$count"
        fi
        measure "transpile_${shape}_$count" "$REPEATS" \
            "$RZA_COMPILER" "$source" --emit-lib -o "$generated"
        if [ "$BACKEND" -eq 1 ] && [ "$shape" = procs ]; then
            measure "backend_${shape}_$count" "$BACKEND_REPEATS" \
                $CC $CFLAGS -c "$generated" -o "$BUILD/${shape}_${count}.o"
        fi
        printf 'artifact_bytes %s_%s.rza %s\n' "$shape" "$count" \
            "$(wc -c <"$source")" >>"$RESULTS"
        printf 'artifact_bytes %s_%s.c %s\n' "$shape" "$count" \
            "$(wc -c <"$generated")" >>"$RESULTS"
    done
done
cat "$RESULTS"
