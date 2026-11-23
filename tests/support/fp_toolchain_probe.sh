#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. ./cc.sh

out=${1:-build/fp-toolchain-probe}
mkdir --parents "$out"
rza_cc_init sanitize include/rza .
strict=(-std=c23 -pedantic -Wall -Wextra -Werror
    -fno-fast-math -ffp-contract=off -fexcess-precision=standard)
case "$CC" in
    *"zig cc"*) strict+=(-Wno-unused-command-line-argument) ;;
esac
optimized=(-O2)
if rza_cc_is_msvc; then strict=(); optimized=(/O2); fi
source=tests/host/fp_toolchain_probe.c

rza_cc "${strict[@]}" "$source" -o "$out/probe-default.exe" 2>"$out/default-compile.err"
test ! -s "$out/default-compile.err"
rza_run "$out/probe-default.exe" >"$out/default-run.out" 2>"$out/default-run.err"
test ! -s "$out/default-run.err"
grep --quiet '^FP_TOOLCHAIN_PROBE OK$' "$out/default-run.out"
rza_cc "${strict[@]}" "${optimized[@]}" "$source" -o "$out/probe.exe" 2>"$out/compile.err"
test ! -s "$out/compile.err"
rza_run "$out/probe.exe" >"$out/run.out" 2>"$out/run.err"
test ! -s "$out/run.err"
grep --quiet '^FP_TOOLCHAIN_PROBE OK$' "$out/run.out"
if rza_cc_is_msvc; then
    rza_cc "${strict[@]}" "${optimized[@]}" /Fa"$out/probe.asm" "$source" \
        -o "$out/probe.exe" 2>"$out/assembly-compile.err"
else
    rza_cc "${strict[@]}" "${optimized[@]}" -S "$source" -o "$out/probe.asm" \
        2>"$out/assembly-compile.err"
fi
test ! -s "$out/assembly-compile.err"
symbols=(mul_add narrow from_u32 from_f32_u64 from_f32_i64 from_f64_u64 from_f64_i64)
for symbol in "${symbols[@]}"; do
    if ! grep --quiet "$symbol" "$out/probe.asm"; then
        echo "FATAL: probe helper was inlined away: $symbol" >&2
        exit 1
    fi
done
if grep -E 'vfmadd|fmadd|fmla' "$out/probe.asm" >/dev/null 2>&1; then
    echo "FATAL: contraction found in strict build" >&2
    exit 1
fi

if rza_cc_is_msvc; then
    CFLAGS=${CFLAGS/\/fp:strict /}
    CFLAGS+=" /wd4723"
    rza_cc "${strict[@]}" "${optimized[@]}" -DFP_PROBE_NEGATIVE /fp:fast /arch:AVX2 \
        /Fa"$out/fast.asm" "$source" -o "$out/fast.exe" >"$out/fast.out" \
        2>"$out/fast.err"
    test ! -s "$out/fast.err"
    grep -E 'vfmadd|fmadd|fmla' "$out/fast.asm" >/dev/null 2>&1
    set +e
    rza_run "$out/fast.exe" >"$out/fast-run.out" 2>"$out/fast-run.err"
    fast_status=$?
    set -e
    if [ "$fast_status" -eq 0 ]; then
        echo "FATAL: /fp:fast was not detected semantically" >&2
        exit 1
    fi
    printf 'NEGATIVE fast-math: assembly and semantic detection\n'
else
    set +e
    rza_cc "${strict[@]}" -ffast-math "$source" -o "$out/fast.exe" \
        >"$out/fast.out" 2>"$out/fast.err"
    fast_status=$?
    set -e
    if [ "$fast_status" -eq 0 ]; then
        echo "FATAL: fast-math configuration was not rejected" >&2
        exit 1
    fi
    if ! grep -E 'fast-math or finite-only mode is enabled' "$out/fast.err" \
            >/dev/null 2>&1; then
        echo "FATAL: fast-math guard did not reject configuration" >&2
        exit 1
    fi
    printf 'NEGATIVE fast-math: compile-time rejection\n'
fi

contract_flags=(-ffp-contract=fast)
if [ -z "${RZA_TARGET_ARCH:-}" ]; then contract_flags+=(-mfma); fi
if rza_cc_is_msvc; then
    rza_cc "${strict[@]}" "${optimized[@]}" -DFP_PROBE_NEGATIVE \
        -DFP_PROBE_ALLOW_CONTRACTION /fp:precise /fp:contract /arch:AVX2 \
        /Fa"$out/contract.asm" "$source" -o "$out/contract.exe" 2>"$out/contract.err"
else
    rza_cc "${strict[@]}" "${optimized[@]}" -DFP_PROBE_ALLOW_CONTRACTION \
        "${contract_flags[@]}" "$source" -o "$out/contract.exe" 2>"$out/contract.err"
    rza_cc "${strict[@]}" "${optimized[@]}" -DFP_PROBE_ALLOW_CONTRACTION \
        "${contract_flags[@]}" -S "$source" -o "$out/contract.asm" \
        2>"$out/contract-assembly.err"
fi
test ! -s "$out/contract.err"
if ! rza_cc_is_msvc; then test ! -s "$out/contract-assembly.err"; fi
grep -E 'vfmadd|fmadd|fmla' "$out/contract.asm" >/dev/null 2>&1
set +e
rza_run "$out/contract.exe" >"$out/contract.out" 2>"$out/contract.err.run"
contract_status=$?
set -e
if [ "$contract_status" -eq 0 ]; then
    echo "FATAL: contraction-only runtime check did not detect FMA" >&2
    exit 1
fi
printf 'NEGATIVE contraction-only: assembly and semantic detection\n'
printf 'FP_TOOLCHAIN_PROBE PASS assembly=compiler-generated compiler=%s\n' "$CC"
