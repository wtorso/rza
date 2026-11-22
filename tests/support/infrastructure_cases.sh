#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."

work=$(mktemp -d "$PWD/build/infrastructure-tests.XXXXXX")
trap 'rm --recursive --force "$work"' EXIT
baseline="$PWD/build/numeric-audit/rez3asm-baseline"
test -x "$baseline"

path_without_c3() {
    local result="" dir
    local -a parts
    IFS=':' read -r -a parts <<<"$PATH"
    for dir in "${parts[@]}"; do
        if [ -x "$dir/c3c" ] || [ -x "$dir/c3c.exe" ]; then continue; fi
        result+="${result:+:}$dir"
    done
    printf '%s\n' "$result"
}

run_negative() {
    local name=$1 path=$2 expected=$3 status
    local log="$work/$name.log"
    timeout 10 env PATH="$path" LOCALAPPDATA= RZA_COMPILER="$baseline" \
        /bin/bash run_tests.sh >"$log" 2>&1
    status=$?
    if [ "$status" -ne 2 ]; then
        printf 'FAIL %s: exit %d, want infrastructure 2; log=%s\n' "$name" "$status" "$log"
        return 1
    fi
    if ! grep --quiet "$expected" "$log"; then
        printf 'FAIL %s: missing diagnostic %s; log=%s\n' "$name" "$expected" "$log"
        return 1
    fi
    if grep --quiet '^PASS ' "$log"; then
        printf 'FAIL %s: source PASS emitted before infrastructure exit; log=%s\n' \
            "$name" "$log"
        return 1
    fi
    printf 'INFRA %s OK exit=2 no-source-pass\n' "$name"
}

clean_path=$(path_without_c3)
if [ "$clean_path" = "$PATH" ]; then
    printf 'FAIL missing_c3c fixture did not hide a real c3c\n' >&2
    exit 1
fi
run_negative missing_c3c "$clean_path" "FATAL: no c3c" || exit 1

mkdir --parents "$work/fake-bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$work/fake-bin/c3c"
chmod +x "$work/fake-bin/c3c"
run_negative failed_build "$work/fake-bin:$PATH" "FATAL:" || exit 1

run_target_negative() {
    local name=$1 expected=$2 path=$3 cc=$4 launcher=$5 expected_pass=$6
    local log="$work/$name.log" target_log="$work/$name.exec.log"
    if [ "$name" = missing_target_log ]; then target_log=""; fi
    timeout 10 env PATH="$path" LOCALAPPDATA= RZA_COMPILER="$baseline" \
        CC="$cc" RZA_TARGET_ARCH=aarch64 RZA_TARGET_LAUNCHER="$launcher" \
        RZA_TARGET_LOG="$target_log" RZA_TARGET_EXPECTED_PASS="$expected_pass" \
        /bin/bash run_tests.sh >"$log" 2>&1
    status=$?
    if [ "$status" -ne 2 ]; then
        printf 'FAIL %s: exit %d, want infrastructure 2; log=%s\n' "$name" "$status" "$log"
        return 1
    fi
    if ! grep --quiet "$expected" "$log"; then
        printf 'FAIL %s: missing diagnostic %s; log=%s\n' "$name" "$expected" "$log"
        return 1
    fi
    if grep --quiet '^PASS ' "$log"; then
        printf 'FAIL %s: source PASS emitted before infrastructure exit; log=%s\n' \
            "$name" "$log"
        return 1
    fi
    printf 'INFRA %s OK exit=2 no-source-pass\n' "$name"
}

if [ -z "${RZA_TARGET_ARCH:-}" ]; then
    echo "HOST_ONLY target infrastructure cases require explicit target mode"
    exit 0
fi

cross_cc="$PWD/build/toolchain/zig-x86_64-linux-0.17.1/zig cc -target aarch64-linux-musl -static"
run_target_negative missing_target_log "target arch" "$PATH" "$cross_cc" \
    /usr/bin/qemu-aarch64 134 || exit 1
run_target_negative missing_target_compiler "compiler" "$PATH" /nonexistent-target-cc \
    /usr/bin/qemu-aarch64 134 || exit 1
run_target_negative mismatched_launcher "launcher" "$PATH" "$cross_cc" /bin/true 134 || exit 1
run_target_negative invalid_expected_pass "RZA_TARGET_EXPECTED_PASS" "$PATH" "$cross_cc" \
    /usr/bin/qemu-aarch64 invalid || exit 1

mkdir --parents "$work/no-readelf-bin" "$work/no-awk-bin"
cp -as /usr/bin/. "$work/no-readelf-bin/"
cp -as /usr/bin/. "$work/no-awk-bin/"
rm --force "$work/no-readelf-bin/readelf" "$work/no-awk-bin/awk"
ln -s "$PWD/build/toolchain/c3/c3c" "$work/no-readelf-bin/c3c"
ln -s "$PWD/build/toolchain/c3/c3c" "$work/no-awk-bin/c3c"
run_target_negative missing_readelf "readelf" "$work/no-readelf-bin" "$cross_cc" \
    /usr/bin/qemu-aarch64 134 || exit 1
run_target_negative missing_awk "awk" "$work/no-awk-bin" "$cross_cc" \
    /usr/bin/qemu-aarch64 134 || exit 1
