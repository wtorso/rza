#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

work=build/target-runner-cases
rm --recursive --force "$work"
mkdir --parents "$work"
zig=build/toolchain/zig-x86_64-linux-0.16.0/zig
test -x "$zig"
printf 'int main(void) { return 42; }\n' >"$work/probe.c"
"$zig" cc -target aarch64-linux-musl -std=c23 -pedantic -Wall -Wextra -Werror \
    -static "$work/probe.c" -o "$work/aarch64"
"$zig" cc -target riscv64-linux-musl -std=c23 -pedantic -Wall -Wextra -Werror \
    -static "$work/probe.c" -o "$work/riscv64"
"$zig" cc -std=c23 -pedantic -Wall -Wextra -Werror \
    "$work/probe.c" -o "$work/x86_64"
printf 'not an executable\n' >"$work/text"
chmod +x "$work/text"

passed=0
expect_case() {
    local name=$1 expected_status=$2 arch=$3 launcher=$4 program=$5 expected_log=$6
    local log="$work/$name.log" status=0 lines=0 path="$PATH"
    if [ "$name" = missing-log ]; then
        log=""
    else
        rm --force "$log"
    fi
    if [ "$name" = missing-readelf ]; then path=/nonexistent; fi
    set +e
    PATH="$path" RZA_TARGET_ARCH="$arch" RZA_TARGET_LAUNCHER="$launcher" \
        RZA_TARGET_LOG="$log" /bin/bash tests/target_run.sh "$program" \
        >"$work/$name.out" 2>"$work/$name.err"
    status=$?
    set -e
    if [ -n "$log" ] && [ -f "$log" ]; then lines=$(wc -l <"$log"); fi
    if [ "$status" -ne "$expected_status" ] || [ "$lines" -ne "$expected_log" ]; then
        printf 'FAIL %s: status=%d want=%d log=%d want=%d\n' \
            "$name" "$status" "$expected_status" "$lines" "$expected_log" >&2
        cat "$work/$name.err" >&2
        return 1
    fi
    passed=$((passed + 1))
}

expect_case missing-arch 2 "" qemu-aarch64-static "$work/aarch64" 0
expect_case missing-launcher 2 aarch64 "" "$work/aarch64" 0
expect_case missing-log 2 aarch64 qemu-aarch64-static "$work/aarch64" 0
expect_case invalid-arch 2 arm64 qemu-aarch64-static "$work/aarch64" 0
expect_case missing-qemu 2 aarch64 /nonexistent-qemu "$work/aarch64" 0
expect_case missing-readelf 2 aarch64 /usr/bin/qemu-aarch64-static "$work/aarch64" 0
expect_case fake-launcher 2 aarch64 /bin/true "$work/aarch64" 0
expect_case text-input 1 aarch64 qemu-aarch64-static "$work/text" 0
expect_case host-aarch64 1 aarch64 qemu-aarch64-static "$work/x86_64" 0
expect_case host-riscv64 1 riscv64 qemu-riscv64-static "$work/x86_64" 0
expect_case wrong-target 1 riscv64 qemu-riscv64-static "$work/aarch64" 0
expect_case aarch64-ok 42 aarch64 qemu-aarch64-static "$work/aarch64" 1
expect_case riscv64-ok 42 riscv64 qemu-riscv64-static "$work/riscv64" 1

. ./cc.sh

expect_init() {
    local name=$1 expected=$2 arch=$3 launcher=$4 log=$5 expected_pass=$6 status=0
    set +e
    CC="$zig cc" RZA_TARGET_ARCH="$arch" RZA_TARGET_LAUNCHER="$launcher" \
        RZA_TARGET_LOG="$log" RZA_TARGET_EXPECTED_PASS="$expected_pass" \
        rza_cc_init sanitize include/rza . >"$work/$name.out" 2>"$work/$name.err"
    status=$?
    set -e
    if [ "$status" -ne "$expected" ]; then
        printf 'FAIL %s: init status=%d want=%d\n' "$name" "$status" "$expected" >&2
        return 1
    fi
    passed=$((passed + 1))
}

expect_rza_run() {
    local name=$1 expected=$2 arch=$3 program=$4 expected_log=$5
    local log="$work/$name.exec.log" status=0 lines=0 launcher="qemu-$arch-static"
    rm --force "$log"
    if [ -z "$arch" ]; then launcher=""; log=""; fi
    set +e
    RZA_TARGET_ARCH="$arch" RZA_TARGET_LAUNCHER="$launcher" \
        RZA_TARGET_LOG="$log" rza_run "$program" >"$work/$name.out" 2>"$work/$name.err"
    status=$?
    set -e
    if [ -f "$log" ]; then lines=$(wc -l <"$log"); fi
    if [ "$status" -ne "$expected" ] || [ "$lines" -ne "$expected_log" ]; then
        printf 'FAIL %s: run status=%d want=%d log=%d want=%d\n' \
            "$name" "$status" "$expected" "$lines" "$expected_log" >&2
        return 1
    fi
    passed=$((passed + 1))
}

expect_init init-missing-log 2 aarch64 qemu-aarch64-static "" 134
expect_init init-missing-launcher 2 aarch64 "" "$work/init.log" 134
expect_init init-missing-arch 2 "" qemu-aarch64-static "$work/init.log" 134
expect_init init-native 0 "" "" "" 134
expect_init init-target 0 aarch64 qemu-aarch64-static "$work/init.log" 134
expect_init init-invalid-pass 2 aarch64 qemu-aarch64-static "$work/init.log" invalid
expect_rza_run hook-native 42 "" "$work/x86_64" 0
expect_rza_run hook-reject 1 aarch64 "$work/x86_64" 0
expect_rza_run hook-target 42 aarch64 "$work/aarch64" 1

printf 'TARGET_RUNNER_CASES OK (%d cases)\n' "$passed"
