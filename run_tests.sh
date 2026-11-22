#!/usr/bin/env bash
# run_tests.sh — полный прогон REZ3-ASM: сборка транспайлера (C3), трансляция,
# компиляция C23 с compiler-specific warnings/sanitizers, запуск и сверка exit/stdout,
# негативные тесты, LSP и fuzz. exit 0 только если всё зелёное.
set -o nounset
cd "$(dirname "$0")"
. ./cc.sh

# компилятор C23 для сгенерированного кода
if [ -z "${CC:-}" ]; then
    if   command -v gcc   >/dev/null 2>&1; then CC="gcc"
    elif command -v zig   >/dev/null 2>&1; then CC="zig cc"
    elif command -v clang >/dev/null 2>&1; then CC="clang"
    else echo "FATAL: no C compiler (gcc | zig | clang)" >&2; exit 2; fi
fi
rza_cc_init sanitize include/rza . || exit 2
BUILD=".test-build-$$"
rm --recursive --force "$BUILD"
mkdir --parents "$BUILD"
trap 'rm --recursive --force "$BUILD"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1 -- $2"; }
ok_host() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY $1"
    else
        ok "$1"
    fi
}

run_style() {
    if ! "$BUILD/rza_tests.exe" line-style >"$BUILD/style.out" 2>&1; then
        bad style "lines longer than 100"
        cat "$BUILD/style.out"
        return
    fi
    ok_host style
}

require_c3c() {
    if command -v c3c >/dev/null 2>&1; then return; fi
    if [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/c3/c3c.exe" ]; then return; fi
    echo "FATAL: no c3c" >&2
    exit 2
}

run_function_style() {
    local c3c_bin="c3c"
    if ! command -v "$c3c_bin" >/dev/null 2>&1; then
        c3c_bin="${LOCALAPPDATA:-}/c3/c3c.exe"
    fi
    if ! "$c3c_bin" compile tests/support/runner.c3 tests/support/harness.c3 \
            tests/support/function_length.c3 tests/support/source_style.c3 \
            tests/integration/deterministic_artifacts.c3 \
            tests/integration/tiny_budgets.c3 tests/integration/fuzz_smoke.c3 \
            tests/oracles/ownership/ownership_model.c3 \
            tests/oracles/ownership/ownership_fuzz.c3 \
            tests/oracles/execution/execution_oracle.c3 \
            tests/oracles/execution/execution_proc_oracle.c3 \
            tests/oracles/execution/execution_proc_model.c3 \
            tests/oracles/execution/execution_cascade_oracle.c3 \
            tests/oracles/execution/execution_cascade_model.c3 \
            tests/oracles/execution/execution_shrink.c3 \
            tests/oracles/execution/execution_coverage.c3 \
            tests/oracles/numeric8/numeric8_oracle.c3 \
            tests/oracles/numeric8/numeric8_reference.c3 \
            tests/oracles/numeric8/numeric8_coverage.c3 \
            tests/oracles/numeric16/numeric16_oracle.c3 \
            tests/oracles/numeric16/numeric16_reference.c3 \
            tests/oracles/numeric16/numeric16_coverage.c3 \
            tests/oracles/numeric32/numeric32_oracle.c3 \
            tests/oracles/numeric32/numeric32_reference.c3 \
            tests/oracles/numeric32/numeric32_coverage.c3 \
            tests/oracles/numeric64/numeric64_oracle.c3 \
            tests/oracles/numeric64/numeric64_reference.c3 \
            tests/oracles/numeric64/numeric64_coverage.c3 \
            tests/integration/lsp/lsp_client.c3 \
            tests/integration/faults/fault_scenarios.c3 \
            tests/integration/faults/fault_smoke.c3 \
            tests/integration/contracts/proc_contracts.c3 \
            tests/integration/contracts/contract_model.c3 \
            tests/integration/contracts/contract_fuzz.c3 \
            tests/integration/lsp/lsp_smoke.c3 \
            tests/integration/lsp/lsp_navigation_smoke.c3 \
            tests/integration/lsp/lsp_completion_smoke.c3 \
            tests/integration/lsp/lsp_references_smoke.c3 \
            tests/integration/lsp/lsp_memory_posix.c3 \
            tests/integration/lsp/lsp_memory_win32.c3 -o "$BUILD/rza_tests" \
            >"$BUILD/function_style.out" 2>&1; then
        echo "FATAL: C3 test runner build failed" >&2
        cat "$BUILD/function_style.out" >&2
        exit 2
    fi
    if [ -f "$BUILD/rza_tests" ] &&
            [ ! "$BUILD/rza_tests" -ef "$BUILD/rza_tests.exe" ]; then
        if ! mv --force "$BUILD/rza_tests" "$BUILD/rza_tests.exe"; then
            bad function_style "cannot normalize C3 test runner"
            return
        fi
    fi
    if ! "$BUILD/rza_tests.exe" function-style >>"$BUILD/function_style.out" 2>&1; then
        bad function_style "function length or scanner error"
        cat "$BUILD/function_style.out"
        return
    fi
    ok_host function_style
}
require_c3c
run_function_style
run_style

echo "== build rez3asm (c3c) =="
if ! bash build_compiler.sh; then
    echo "FATAL: compiler build failed; refusing stale binary" >&2
    exit 2
fi
if [ -z "${RZA_COMPILER:-}" ]; then
    RZA_COMPILER="./build/bin/rez3asm"
    if [ "${OS:-}" = "Windows_NT" ]; then RZA_COMPILER="./build/bin/rez3asm.exe"; fi
fi
TR="$RZA_COMPILER"

compare_text() {
    local expected=$1 actual=$2
    tr --delete '\r' <"$expected" >"$BUILD/expected.lf"
    diff --unified "$BUILD/expected.lf" "$actual"
}

# легальная программа: транслируется, компилируется без warnings,
# stdout совпадает с tests/$1.expected
run_good() {
    local t=$1
    local dir=${DIR:-tests}
    if ! $TR "$dir/$t.rza" --emit-c -o "$BUILD/$t.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile failed (want exit 0)"; cat "$BUILD/$t.trerr"
        return
    fi
    if ! rza_cc "$BUILD/$t.c" -o "$BUILD/$t.exe" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    if ! rza_run "$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "runtime failed (want exit 0)"; cat "$BUILD/$t.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! compare_text "$dir/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        compare_text "$dir/$t.expected" "$BUILD/$t.out.lf"
        return
    fi
    ok "$t"
}

# Runtime-fault: $2 — substring диагностики, а при $3=exact — полный stderr.
run_dead() {
    local t=${1:-dead_link}
    local want=${2:-FAULT}
    local exact=${3:-}
    if ! $TR "tests/$t.rza" --emit-c -o "$BUILD/$t.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile failed (want exit 0: runtime-fault is legal)"
        cat "$BUILD/$t.trerr"
        return
    fi
    if ! rza_cc "$BUILD/$t.c" -o "$BUILD/$t.exe" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    rza_run "$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"
    local status=$?
    if [ "$status" -eq 0 ]; then
        bad "$t" "exited 0 (want runtime fault)"
        return
    fi
    if [ "$exact" = exact ] && [ "$status" -ne 1 ]; then
        bad "$t" "exit $status (want 1)"
        return
    fi
    if [ -f "tests/$t.expected" ]; then
        tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
        if ! compare_text "tests/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
            bad "$t" "stdout mismatch before fault"
            compare_text "tests/$t.expected" "$BUILD/$t.out.lf"
            return
        fi
    elif [ "$exact" = exact ] && [ -s "$BUILD/$t.out" ]; then
        bad "$t" "stdout before fault (want empty)"; cat "$BUILD/$t.out"
        return
    fi
    if [ "$exact" = exact ]; then
        printf '%s\n' "$want" >"$BUILD/$t.stderr.expected"
        tr --delete '\r' <"$BUILD/$t.runerr" >"$BUILD/$t.runerr.lf"
        if ! compare_text "$BUILD/$t.stderr.expected" "$BUILD/$t.runerr.lf" \
                >/dev/null 2>&1; then
            bad "$t" "stderr mismatch"
            compare_text "$BUILD/$t.stderr.expected" "$BUILD/$t.runerr.lf"
            return
        fi
    elif ! grep --quiet "$want" "$BUILD/$t.runerr"; then
        bad "$t" "missing diagnostic: $want"; cat "$BUILD/$t.runerr"
        return
    fi
    ok "$t"
}

run_abort() {
    local t=$1 want=$2
    if ! $TR "tests/$t.rza" --emit-c -o "$BUILD/$t.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile failed"; cat "$BUILD/$t.trerr"
        return
    fi
    if ! rza_cc "$BUILD/$t.c" -o "$BUILD/$t.exe" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings"; cat "$BUILD/$t.ccerr"
        return
    fi
    if ! rza_run "$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "runtime failed (want exit 0 with abort)"; cat "$BUILD/$t.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! compare_text "tests/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        compare_text "tests/$t.expected" "$BUILD/$t.out.lf"
        return
    fi
    if ! grep --quiet "$want" "$BUILD/$t.runerr"; then
        bad "$t" "missing abort diagnostic"; cat "$BUILD/$t.runerr"
        return
    fi
    ok "$t"
}

# незаконная программа: exit 1, stderr содержит [$2]; $3 — полный golden (опционально)
run_viol() {
    local t=$1 rule=$2 expected=${3:-} status
    $TR "tests/$t.rza" >"$BUILD/$t.out" 2>"$BUILD/$t.err"
    status=$?
    if [ "$status" -ne 1 ]; then
        bad "$t" "transpiler exit $status (want exit 1)"
        cat "$BUILD/$t.err"
        return
    fi
    if ! grep --quiet "\[$rule\]" "$BUILD/$t.err"; then
        bad "$t" "no [$rule] in stderr"; cat "$BUILD/$t.err"
        return
    fi
    if [ -n "$expected" ]; then
        tr --delete '\r' <"$BUILD/$t.err" >"$BUILD/$t.err.lf"
        if ! compare_text "$expected" "$BUILD/$t.err.lf" >/dev/null 2>&1; then
            bad "$t" "stderr mismatch"
            compare_text "$expected" "$BUILD/$t.err.lf"
            return
        fi
    fi
    ok_host "$t"
}

run_viol_contract() {
    local pass_before=$PASS fail_before=$FAIL previous_tr=$TR
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "VIOLATION line 1 [STRUCT]: fake" >&2' 'exit 2' \
        >"$BUILD/fake-compiler"
    chmod +x "$BUILD/fake-compiler"
    printf '%s\n' 'VIOLATION line 1 [STRUCT]: fake' >"$BUILD/fake.expected"
    TR="$BUILD/fake-compiler" run_viol fake_contract STRUCT "$BUILD/fake.expected" \
        >"$BUILD/fake-contract.log" 2>&1
    TR=$previous_tr
    if [ "$PASS" -ne "$pass_before" ]; then
        PASS=$pass_before
        bad run_viol_contract "accepted compiler exit 2"
        return
    fi
    if [ "$FAIL" -ne $((fail_before + 1)) ]; then
        bad run_viol_contract "did not reject compiler exit 2"
        return
    fi
    FAIL=$fail_before
    ok_host run_viol_contract
}

run_cli_contract() {
    local status version
    "$TR" --help >"$BUILD/cli_help.out" 2>"$BUILD/cli_help.err"
    status=$?
    if [ "$status" -ne 0 ] || ! compare_text tests/cli_help.expected \
            "$BUILD/cli_help.out" || [ -s "$BUILD/cli_help.err" ]; then
        bad cli_contract "--help must print exact help to stdout and exit 0"
        return
    fi
    version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' project.json)
    printf 'rez3asm %s\n' "$version" >"$BUILD/cli_version.expected"
    "$TR" --version >"$BUILD/cli_version.out" 2>"$BUILD/cli_version.err"
    status=$?
    if [ "$status" -ne 0 ] || ! compare_text "$BUILD/cli_version.expected" \
            "$BUILD/cli_version.out" || [ -s "$BUILD/cli_version.err" ]; then
        bad cli_contract "--version must match project.json and exit 0"
        return
    fi
    "$TR" >"$BUILD/cli_noargs.out" 2>"$BUILD/cli_noargs.err"
    status=$?
    if [ "$status" -ne 2 ] || [ -s "$BUILD/cli_noargs.out" ] || \
            ! compare_text tests/cli_help.expected "$BUILD/cli_noargs.err"; then
        bad cli_contract "no arguments must print help to stderr and exit 2"
        return
    fi
    "$TR" --help tests/fib.rza >"$BUILD/cli_mixed.out" 2>"$BUILD/cli_mixed.err"
    if [ "$?" -ne 2 ]; then
        bad cli_contract "--help with an input must be a usage error"
        return
    fi
    "$TR" tests/fib.rza tests/counter.rza >"$BUILD/cli_two.out" 2>"$BUILD/cli_two.err"
    if [ "$?" -ne 2 ]; then
        bad cli_contract "want exit 2 for two input files"
        return
    fi
    ok_host cli_contract
}

run_c3() {
    local name=$1 command=$2
    if "$BUILD/rza_tests.exe" "$command"; then ok "$name"
    else bad "$name" "C3 scenario failed"; fi
}

run_lsp_smoke() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY lsp_smoke x86_64 language server"
    else
        run_c3 lsp_smoke lsp
    fi
}
run_fuzz() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY fuzz parser and checker"
    else
        run_c3 fuzz fuzz
    fi
}
run_ownership_fuzz() { run_c3 ownership_fuzz ownership; }
run_execution_oracle() { run_c3 execution_oracle oracle; }
run_numeric8_oracle() { run_c3 numeric8_oracle numeric8-oracle; }
run_numeric16_oracle() { run_c3 numeric16_oracle numeric16-oracle; }
run_numeric32_oracle() { run_c3 numeric32_oracle numeric32-oracle; }
run_numeric64_oracle() { run_c3 numeric64_oracle numeric64-oracle; }
run_fault_smoke() { run_c3 fault_smoke faults; }
run_proc_contracts() { run_c3 proc_contracts contracts; }
run_contract_fuzz() { run_c3 contract_fuzz contract-fuzz; }
run_deterministic_artifacts() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY deterministic_artifacts generated C text"
    else
        run_c3 deterministic_artifacts artifacts
    fi
}
run_tiny_budgets() { run_c3 tiny_budgets budgets; }

run_benchmark_sources() {
    if ! bash bench/check.sh "$BUILD/bench" >"$BUILD/bench.log" 2>&1; then
        bad benchmark_sources "workload outputs differ or build failed"
        cat "$BUILD/bench.log"
        return
    fi
    ok benchmark_sources
}

run_async_mutants() {
    local base="$BUILD/async-mutants"
    mkdir --parents "$base"
    if ! $TR tests/lib_async_fault.rza --emit-lib -o "$base/cancel.c" ||
            ! sed 's/rez_async_cancel(&g_async);/(void)\&g_async;/' \
                "$base/cancel.c" >"$base/no_cancel.c" ||
            ! rza_cc -DGENERATED_RZA=\"$base/no_cancel.c\" \
                tests/lib_async_fault.harness.c -o "$base/no_cancel.exe"; then
        bad async_cancel_mutation "build failed"
        return
    fi
    if rza_run "$base/no_cancel.exe" >"$base/no_cancel.out" 2>&1; then
        bad async_cancel_mutation "host accepted execution without cancellation"
        return
    fi
    ok async_cancel_mutation

    if ! $TR tests/view_async_out_widen.rza --emit-c -o "$base/view.c" ||
            ! sed -e 's/voff_m_tail_m,/0,/' -e 's/vlen_m_tail_m,/8,/' \
                "$base/view.c" >"$base/widened.c" ||
            ! rza_cc "$base/widened.c" -o "$base/widened.exe"; then
        bad async_view_mutation "build failed"
        return
    fi
    if ! rza_run "$base/widened.exe" >"$base/widened.out" 2>&1; then
        bad async_view_mutation "widened view still faults"
        return
    fi
    ok async_view_mutation

    if ! $TR tests/async_out_reuse.rza --emit-c -o "$base/gen.c" ||
            ! sed 's/ac_out_gen_1 = 1;/ac_out_gen_1 = 4294967295;/' \
                "$base/gen.c" >"$base/exhausted.c" ||
            ! rza_cc "$base/exhausted.c" -o "$base/exhausted.exe"; then
        bad async_generation_exhaustion "build failed"
        return
    fi
    if rza_run "$base/exhausted.exe" >"$base/exhausted.out" 2>"$base/exhausted.err"; then
        bad async_generation_exhaustion "generation wrap was accepted"
        return
    fi
    if ! grep --quiet "FAULT line 5: async output generation exhausted" \
            "$base/exhausted.err"; then
        bad async_generation_exhaustion "missing generation diagnostic"
        return
    fi
    ok async_generation_exhaustion
}

run_c3_unit() {
    if [ -n "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY c3_unit x86_64 compiler internals"
        return
    fi
    local c3c_bin="c3c"
    if ! command -v "$c3c_bin" >/dev/null 2>&1; then
        c3c_bin="${LOCALAPPDATA:-}/c3/c3c.exe"
    fi
    if ! "$c3c_bin" compile-test src/rez3asm.c3 src/compiler/model.c3 \
            src/compiler/numeric.c3 src/compiler/numeric_parse.c3 src/compiler/layout.c3 \
            src/compiler/checker.c3 src/compiler/emitter.c3 src/lsp/server.c3 \
            src/lsp/navigation.c3 src/lsp/completion.c3 src/lsp/references.c3 \
            src/memory_guard.c3 src/scratch_memory.c3 tests/unit/output_writer_test.c3 \
            tests/unit/memory_guard_test.c3 tests/unit/checker_budget_test.c3 \
            tests/unit/numeric_model_test.c3 tests/unit/numeric8_test.c3 \
            tests/unit/numeric16_test.c3 tests/unit/numeric32_test.c3 \
            tests/unit/numeric64_test.c3 tests/unit/layout_test.c3 \
            tests/unit/view_test.c3 tests/unit/lsp_navigation_test.c3 \
            tests/support/harness.c3 tests/support/function_length.c3 \
            tests/support/source_style.c3 tests/unit/source_style_test.c3 \
            tests/unit/function_length_test.c3 \
            -o c3_tests --output-dir "$BUILD" >"$BUILD/c3_tests.log" 2>&1; then
        bad c3_unit "C3 unit tests failed"; cat "$BUILD/c3_tests.log"
        return
    fi
    ok c3_unit
}

# lib-режим: $1.rza --emit-lib + компиляция с tests/lib_harness.c, запуск,
# сверка с tests/$1.expected
run_lib() {
    local t=$1
    if ! $TR "tests/$t.rza" --emit-lib -o "$BUILD/$t.lib.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile --emit-lib failed"; cat "$BUILD/$t.trerr"
        return
    fi
    if [ -f "tests/$t.harness.c" ]; then
        HARNESS="tests/$t.harness.c"
    else
        HARNESS="tests/lib_harness.c"
    fi
    local -a sources=("$BUILD/$t.lib.c")
    if [ "$t" = lib_async_fault ]; then
        sources=(-DGENERATED_RZA=\"$BUILD/$t.lib.c\")
    fi
    if ! rza_cc "${sources[@]}" "$HARNESS" \
            -o "$BUILD/$t.exe" 2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    if ! rza_run "$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "runtime failed (want exit 0)"; cat "$BUILD/$t.runerr"
        return
    fi
    if [ -s "$BUILD/$t.runerr" ]; then
        bad "$t" "library wrote stderr by default"; cat "$BUILD/$t.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! compare_text "tests/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        compare_text "tests/$t.expected" "$BUILD/$t.out.lf"
        return
    fi
    ok "$t"
}

# lib-режим, только трансляция + компиляция (без запуска)
run_lib_compile() {
    local t=$1
    if ! $TR "tests/$t.rza" --emit-lib -o "$BUILD/$t.lib.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile --emit-lib failed"; cat "$BUILD/$t.trerr"
        return
    fi
    if ! rza_cc_compile -c "$BUILD/$t.lib.c" -o "$BUILD/$t.lib.o" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    ok "$t"
}

run_crc32c_portable() {
    if [ -z "${RZA_TARGET_ARCH:-}" ]; then
        echo "HOST_ONLY crc32c_portable_vectors non-x86 target only"
        return
    fi
    if ! rza_cc tests/host/crc32c_portable_vectors.c -o "$BUILD/crc32c_portable.exe" \
            2>"$BUILD/crc32c_portable.ccerr"; then
        bad crc32c_portable "compile failed"; cat "$BUILD/crc32c_portable.ccerr"
        return
    fi
    if [ -s "$BUILD/crc32c_portable.ccerr" ]; then
        bad crc32c_portable "compiler warnings"; cat "$BUILD/crc32c_portable.ccerr"
        return
    fi
    if ! rza_run "$BUILD/crc32c_portable.exe"; then
        bad crc32c_portable "known vector mismatch"
        return
    fi
    ok crc32c_portable
}

run_runtime_safety() {
    if ! rza_cc tests/host/runtime_safety.c -o "$BUILD/runtime_safety.exe" \
            2>"$BUILD/runtime_safety.ccerr"; then
        bad runtime_safety "compile failed"; cat "$BUILD/runtime_safety.ccerr"
        return
    fi
    if [ -s "$BUILD/runtime_safety.ccerr" ]; then
        bad runtime_safety "compiler warnings (want zero)"
        cat "$BUILD/runtime_safety.ccerr"
        return
    fi
    if ! rza_run "$BUILD/runtime_safety.exe"; then
        bad runtime_safety "runtime checks failed"
        return
    fi
    ok runtime_safety
}

run_shop() {
    if ! rza_cc tests/reference/shop.c -o "$BUILD/shop.exe" \
            2>"$BUILD/shop.ccerr"; then
        bad shop "compile failed"; cat "$BUILD/shop.ccerr"
        return
    fi
    if ! rza_run "$BUILD/shop.exe" >"$BUILD/shop.out" 2>"$BUILD/shop.runerr"; then
        bad shop "runtime failed"; cat "$BUILD/shop.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/shop.out" >"$BUILD/shop.out.lf"
    if ! compare_text tests/shop.expected "$BUILD/shop.out.lf"; then
        bad shop "stdout mismatch"
        return
    fi
    ok shop
}

run_reference() {
    if ! rza_cc tests/reference/rez3check.c \
            -o "$BUILD/rez3check.exe" 2>"$BUILD/rez3check.ccerr"; then
        bad reference "C23 compile failed"; cat "$BUILD/rez3check.ccerr"
        return
    fi
    if [ -s "$BUILD/rez3check.ccerr" ]; then
        bad reference "compiler warnings (want zero)"; cat "$BUILD/rez3check.ccerr"
        return
    fi
    : >"$BUILD/deep.rz3"
    echo "frame f0 -" >>"$BUILD/deep.rz3"
    i=1
    # MAXF=256 включает field, поэтому f0..f254 — предел без LIMIT.
    while [ "$i" -lt 255 ]; do
        echo "frame f$i f$((i - 1))" >>"$BUILD/deep.rz3"
        i=$((i + 1))
    done
    echo "leave f0" >>"$BUILD/deep.rz3"
    if ! rza_run "$BUILD/rez3check.exe" "$BUILD/deep.rz3" >"$BUILD/deep.ref.out"; then
        bad reference "deep decay failed"; cat "$BUILD/deep.ref.out"
        return
    fi
    if ! grep --quiet "violations=0" "$BUILD/deep.ref.out"; then
        bad reference "unexpected violations"; cat "$BUILD/deep.ref.out"
        return
    fi
    # Старый link после raise остаётся жив: его owner/home не менялись.
    printf 'frame A -\nframe B A\ncell X B\nlink M X B\nraise X A\ncasc C M > OUT A\n' \
        >"$BUILD/raise_old.ref.rz3"
    if ! rza_run "$BUILD/rez3check.exe" "$BUILD/raise_old.ref.rz3" \
            >"$BUILD/raise_old.ref.out"; then
        bad reference "live mediator rejected after raise"; cat "$BUILD/raise_old.ref.out"
        return
    fi
    if ! grep --quiet "violations=0" "$BUILD/raise_old.ref.out"; then
        bad reference "unexpected raise violations"; cat "$BUILD/raise_old.ref.out"
        return
    fi
    printf '%s\n' 'await %r0' >"$BUILD/await.ref.rz3"
    if ! rza_run "$BUILD/rez3check.exe" "$BUILD/await.ref.rz3" >"$BUILD/await.ref.out"; then
        bad reference "valid await rejected"; cat "$BUILD/await.ref.out"
        return
    fi
    if ! grep --quiet "violations=0" "$BUILD/await.ref.out"; then
        bad reference "unexpected await violations"; cat "$BUILD/await.ref.out"
        return
    fi
    ok reference
}

check_ref_reject() {
    local name=$1 expected=$2 status
    rza_run "$BUILD/rez3check.exe" >"$BUILD/$name.out"
    status=$?
    if [ "$status" -ne 1 ]; then
        bad "$name" "want exit 1, got $status"; cat "$BUILD/$name.out"
        return 1
    fi
    if ! grep --quiet "$expected" "$BUILD/$name.out"; then
        bad "$name" "missing $expected"; cat "$BUILD/$name.out"
        return 1
    fi
    return 0
}

run_reference_invalid() {
    check_ref_reject ref_malformed STRUCT \
        < <(printf 'frame only_one_operand\n') || return
    check_ref_reject ref_overlong "line too long" \
        < <(printf '%512s\n' x) || return
    check_ref_reject ref_source_limit "source bytes" \
        < <(printf '%1048577s' x) || return
    check_ref_reject ref_raise_dead_source I4 \
        < <(printf 'frame A -\nframe B A\ncell X B\nleave A\nraise X field\n') || return
    check_ref_reject ref_raise_home_casc I3 \
        < <(printf '%s\n' 'frame A -' 'frame B A' 'cell X B' 'raise X A' \
            'link X_M X A' 'leave B' 'casc C X_M > OUT A') || return
    check_ref_reject ref_await_suffix STRUCT \
        < <(printf '%s\n' 'await %r0junk') || return
    check_ref_reject ref_await_missing STRUCT \
        < <(printf '%s\n' 'await') || return
    check_ref_reject ref_await_extra STRUCT \
        < <(printf '%s\n' 'await %r0 %r1') || return
    check_ref_reject ref_await_range STRUCT \
        < <(printf '%s\n' 'await %r16') || return
    ok reference_invalid
}

run_build_parallel() {
    local p1 p2 status
    if ! bash tests/support/infrastructure_cases.sh >"$BUILD/infrastructure.log" 2>&1; then
        bad build_parallel "compiler infrastructure contract failed"
        cat "$BUILD/infrastructure.log"
        return
    fi
    bash build_compiler.sh >"$BUILD/parallel1.log" 2>&1 & p1=$!
    bash build_compiler.sh >"$BUILD/parallel2.log" 2>&1 & p2=$!
    status=0
    wait "$p1" || status=1
    wait "$p2" || status=1
    if [ "$status" -ne 0 ]; then
        bad build_parallel "concurrent compiler builds failed"
        cat "$BUILD/parallel1.log" "$BUILD/parallel2.log"
        return
    fi
    local expected="./build/bin/rez3asm"
    if [ "${OS:-}" = "Windows_NT" ]; then expected="./build/bin/rez3asm.exe"; fi
    if [ ! -x "$expected" ]; then
        bad build_parallel "native compiler missing: $expected"
        return
    fi
    ok_host build_parallel
}

run_viol_contract

echo "== REZ3-ASM test run (compiler: $CC) =="
for t in fib counter back_button cascade indexed decay_subtree casc_out_med \
         mangle_label mangle_proc mangle_cav no_cells unaligned; do
    run_good "$t"
done
run_good imm_bounds
run_good arith_wrap
run_good shift_guard
run_good ushr
run_good checked_arith
run_good crc32c_u64
run_good crc32c_name_collision
run_good hoist_prefix
run_good hoist_dead_branch
run_good hoist_call
run_good mov_self
run_good slt_self
run_good capacity_guard
run_good typed_table
run_good compare_edges
run_good skipped_decay
run_good cav_reuse
run_good async_fifo
run_good async_out_reuse
run_good async_await_empty
run_abort async_abort "ABORT line 11: cascade blocked: dead mediator out_m"
run_abort view_async_abort "ABORT line 18: cascade job: dead mediator produced_m"
run_abort typed_ownership "ABORT line 39: cascade blocked: dead mediator temp_m"
run_good async_proc_drain
run_good async_framefree_drain
run_good async_proc_pending
run_good async_proc_repeat
run_abort async_proc_abort "ABORT line 10: cascade blocked: dead mediator out_m"
run_dead async_pending_out "FAULT line 12: dead mediator out_m"
run_dead async_repeat "FAULT line 5: async task bump already pending"
run_dead async_queue_full "FAULT line 259: async queue full"
run_viol viol_async_home I3
run_viol viol_await_operand STRUCT
run_viol viol_await_casc STRUCT
run_viol viol_host_await STRUCT
run_good i64_immediates
run_good storeb
run_good slt
run_good numeric8_access
run_good numeric8_wrap
run_good numeric8_div_shift
run_good numeric8_async
run_good numeric16_access
run_good numeric16_layout
run_good numeric16_wrap
run_good numeric16_div_shift
run_good numeric16_async
run_good numeric32_access
run_good numeric32_layout
run_good numeric32_wrap
run_good numeric32_div_shift
run_good numeric32_async
run_good numeric64_access
run_good numeric64_layout
run_good numeric64_wrap
run_good numeric64_div_shift
run_good numeric64_async
run_dead numeric64_cadd_i64_overflow "FAULT line 2: arithmetic overflow" exact
run_dead numeric64_cinc_i64_overflow "FAULT line 2: arithmetic overflow" exact
run_dead numeric64_cdec_u64_underflow "FAULT line 2: arithmetic overflow" exact
run_dead numeric64_div_i64_min_minus_one "FAULT line 2: division" exact
run_dead numeric64_div_u64_zero "FAULT line 3: division" exact
run_dead numeric64_shift_i64_negative "FAULT line 2: shift" exact
run_dead numeric64_shift_u64_sixty_four "FAULT line 2: shift" exact
run_dead numeric64_checked_index_attack "FAULT line 4: arithmetic overflow" exact
run_dead numeric64_checked_index_proc "FAULT line 5: arithmetic overflow" exact
run_dead numeric64_checked_index_sync "FAULT line 5: arithmetic overflow" exact
run_dead numeric64_checked_index_async "FAULT line 5: out of bounds data_m" exact
run_dead numeric64_async_overflow "FAULT line 5: arithmetic overflow" exact
run_dead numeric32_cadd_i32_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric32_cinc_i32_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric32_cdec_u32_underflow "FAULT line 2: arithmetic overflow"
run_dead numeric32_div_i32_min_minus_one "FAULT line 2: division"
run_dead numeric32_div_u32_zero "FAULT line 3: division"
run_dead numeric32_shift_i32_negative "FAULT line 2: shift"
run_dead numeric32_shift_u32_thirty_two "FAULT line 2: shift"
run_dead numeric32_checked_index_attack "FAULT line 4: arithmetic overflow"
run_dead numeric32_checked_index_proc "FAULT line 5: arithmetic overflow"
run_dead numeric32_checked_index_sync "FAULT line 5: arithmetic overflow"
run_dead numeric32_checked_index_async "FAULT line 5: arithmetic overflow"
run_dead numeric8_cadd_i8_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric8_cadd_u8_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric8_cinc_i8_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric8_cdec_u8_underflow "FAULT line 2: arithmetic overflow"
run_dead numeric8_div_i8_min_minus_one "FAULT line 2: division"
run_dead numeric8_div_u8_zero "FAULT line 3: division"
run_dead numeric8_shift_u8_eight "FAULT line 2: shift"
run_dead numeric8_checked_index_attack "FAULT line 4: arithmetic overflow"
run_dead numeric16_cadd_i16_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric16_cinc_i16_overflow "FAULT line 2: arithmetic overflow"
run_dead numeric16_cdec_u16_underflow "FAULT line 2: arithmetic overflow"
run_dead numeric16_div_i16_min_minus_one "FAULT line 2: division"
run_dead numeric16_div_u16_zero "FAULT line 3: division"
run_dead numeric16_shift_i16_negative "FAULT line 2: shift"
run_dead numeric16_shift_u16_sixteen "FAULT line 2: shift"
run_dead numeric16_checked_index_attack "FAULT line 4: arithmetic overflow"
run_dead numeric16_checked_index_proc "FAULT line 5: arithmetic overflow"
run_dead numeric16_checked_index_sync "FAULT line 5: arithmetic overflow"
run_dead numeric16_checked_index_async "FAULT line 5: arithmetic overflow"
run_dead numeric16_view_raw_oob "FAULT line 5: out of bounds raw_v_m"
run_dead numeric16_view_typed_oob "FAULT line 6: out of bounds pairs_v_m"
run_dead numeric32_view_raw_oob "FAULT line 5: out of bounds raw_v_m"
run_dead numeric32_view_typed_oob "FAULT line 6: out of bounds pairs_v_m"
run_dead numeric64_view_raw_oob "FAULT line 5: out of bounds raw_v_m"
run_dead numeric64_view_typed_oob "FAULT line 6: out of bounds pairs_v_m"
run_viol viol_numeric8_i8_literal STRUCT tests/viol_numeric8_i8_literal.stderr
run_viol viol_numeric8_u8_literal STRUCT tests/viol_numeric8_u8_literal.stderr
run_viol viol_numeric8_negative_hex STRUCT tests/viol_numeric8_negative_hex.stderr
run_viol viol_numeric8_opcode_type STRUCT tests/viol_numeric8_opcode_type.stderr
run_viol viol_numeric8_layout_mismatch STRUCT tests/viol_numeric8_layout_mismatch.stderr
run_viol viol_numeric8_reserved STRUCT tests/viol_numeric8_reserved.stderr
run_viol viol_numeric16_i16_literal STRUCT tests/viol_numeric16_i16_literal.stderr
run_viol viol_numeric16_u16_literal STRUCT tests/viol_numeric16_u16_literal.stderr
run_viol viol_numeric16_negative_hex STRUCT tests/viol_numeric16_negative_hex.stderr
run_viol viol_numeric16_opcode_type STRUCT tests/viol_numeric16_opcode_type.stderr
run_viol viol_numeric16_layout_mismatch STRUCT tests/viol_numeric16_layout_mismatch.stderr
run_viol viol_numeric16_reserved STRUCT tests/viol_numeric16_reserved.stderr
run_viol viol_numeric16_view_bounds STRUCT tests/viol_numeric16_view_bounds.stderr
run_viol viol_numeric32_i32_literal STRUCT tests/viol_numeric32_i32_literal.stderr
run_viol viol_numeric32_u32_literal STRUCT tests/viol_numeric32_u32_literal.stderr
run_viol viol_numeric32_negative_hex STRUCT tests/viol_numeric32_negative_hex.stderr
run_viol viol_numeric32_opcode_type STRUCT tests/viol_numeric32_opcode_type.stderr
run_viol viol_numeric32_layout_mismatch STRUCT tests/viol_numeric32_layout_mismatch.stderr
run_viol viol_numeric32_reserved STRUCT tests/viol_numeric32_reserved.stderr
run_viol viol_numeric32_view_bounds STRUCT tests/viol_numeric32_view_bounds.stderr
run_viol viol_numeric64_i64_literal STRUCT tests/viol_numeric64_i64_literal.stderr
run_viol viol_numeric64_u64_literal STRUCT tests/viol_numeric64_u64_literal.stderr
run_viol viol_numeric64_negative_hex STRUCT tests/viol_numeric64_negative_hex.stderr
run_viol viol_numeric64_opcode_type STRUCT tests/viol_numeric64_opcode_type.stderr
run_viol viol_numeric64_layout_mismatch STRUCT tests/viol_numeric64_layout_mismatch.stderr
run_viol viol_numeric64_reserved STRUCT tests/viol_numeric64_reserved.stderr
run_viol viol_numeric64_view_bounds STRUCT tests/viol_numeric64_view_bounds.stderr
run_viol viol_i64_immediate STRUCT
run_viol viol_i64_hex STRUCT
run_viol viol_storeb STRUCT
run_viol viol_layout_decl STRUCT tests/viol_layout_decl.stderr
run_viol viol_layout_dup DUP tests/viol_layout_dup.stderr
run_viol viol_layout_use STRUCT tests/viol_layout_use.stderr
run_viol viol_layout_access STRUCT tests/viol_layout_access.stderr
run_viol viol_layout_scope STRUCT tests/viol_layout_scope.stderr
run_viol viol_layout_index STRUCT tests/viol_layout_index.stderr
run_good views
run_good view_sync
run_dead view_sync_skipped "FAULT line 8: dead mediator local_m"
run_good view_async_out
run_good view_unconstructed
run_dead view_fault_range "FAULT line 4: invalid view bad_m"
run_dead view_fault_access "FAULT line 5: out of bounds dynamic_m"
run_dead view_fault_dead "FAULT line 6: dead mediator dead_view_m"
run_dead view_fault_typed "FAULT line 5: invalid view bad_typed_m"
run_dead view_async_out_widen "FAULT line 22: out of bounds tail_m"
run_viol viol_view_range STRUCT tests/viol_view_range.stderr
run_viol viol_view_async STRUCT tests/viol_view_async.stderr
run_viol viol_view_escape SCOPE tests/viol_view_escape.stderr
run_viol viol_view_noninput STRUCT tests/viol_view_noninput.stderr
run_dead storeb_oob "FAULT line 5: out of bounds x_m"
run_dead typed_index_negative "FAULT line 5: out of bounds entries_m"
run_dead typed_index_min "FAULT line 5: out of bounds entries_m"
run_dead typed_index_huge "FAULT line 5: out of bounds entries_m"
run_dead typed_scalar_index "FAULT line 5: out of bounds entries_m"
run_dead cav_reentry "FAULT line 3: frame allocation f"
run_dead raise_home "FAULT line 9: dead mediator x_m"
run_dead bounds_dynamic "FAULT line 6: out of bounds x_m"
run_dead bounds_narrow_dynamic "FAULT line 4: out of bounds x_m"
run_dead bounds_casc_dynamic "FAULT line 7: out of bounds x_m"
run_dead div_zero "FAULT line 3: division"
run_dead div_overflow "FAULT line 4: division"
run_dead mod_overflow "FAULT line 4: division"
run_dead shift_range "FAULT line 2: shift"
run_dead shift_negative "FAULT line 3: shift"
run_dead ushr_range "FAULT line 2: shift"
run_dead ushr_negative "FAULT line 3: shift"
run_dead shift_ibft "FAULT line 6: shift"
run_dead checked_add_overflow "FAULT line 2: arithmetic overflow"
run_dead checked_sub_overflow "FAULT line 2: arithmetic overflow"
run_dead checked_mul_overflow "FAULT line 2: arithmetic overflow"
run_dead checked_inc_overflow "FAULT line 2: arithmetic overflow"
run_dead checked_dec_overflow "FAULT line 2: arithmetic overflow"
run_dead checked_proc_overflow "FAULT line 3: arithmetic overflow"
run_dead checked_casc_overflow "FAULT line 7: arithmetic overflow"
run_dead checked_quota_attack "FAULT line 4: arithmetic overflow"
run_dead checked_index_attack "FAULT line 6: arithmetic overflow"
run_dead checked_numeric_overflow "FAULT line 16: arithmetic overflow"
run_viol viol_bounds_imm STRUCT
run_viol viol_bounds_negative STRUCT
run_viol viol_aligned_size STRUCT
run_viol viol_res_sum_overflow STRUCT
run_viol viol_cap_out_overflow STRUCT
run_viol viol_frame_static_budget STRUCT
run_viol viol_total_static_budget STRUCT
run_runtime_safety
run_crc32c_portable
run_shop
run_reference
run_reference_invalid
run_build_parallel

# примеры с независимо вычисленным ожидаемым выводом
for t in hello ring_buffer shop; do
    DIR=examples run_good "$t"
done
run_dead dead_link "FAULT line 10: dead mediator acc_m"
run_dead ret_dead "FAULT line 8: dead mediator x_m"
run_dead hoist_dead_prefix "FAULT line 6: dead mediator x_m"
run_dead hoist_dead_decay "FAULT line 10: dead mediator x_m"
run_good raise_old_med
run_viol viol_raise_home_casc I3
run_viol viol_casc_missing_frame STRUCT
run_viol viol_host_abi STRUCT
run_viol viol_proc_colon STRUCT
run_viol viol_i2        I2
run_viol viol_i4        I4
run_viol viol_jump      STRUCT
run_viol viol_jump_casc STRUCT
run_viol viol_scope     SCOPE
run_viol viol_i1        I1
run_viol viol_i3sync    I3
run_viol viol_i3async   I3
run_viol viol_decay     DECAY
run_viol viol_decay_field DECAY
run_viol viol_dup       DUP
run_viol viol_extra_ops STRUCT
run_viol viol_casc_dup  DUP
run_viol viol_recursive STRUCT
run_viol viol_shadow    DUP
# Покрытие веток чекера.
run_viol viol_res_overflow STRUCT
run_viol viol_ret_casc I3
run_viol viol_bad_name  STRUCT
run_viol viol_bad_reg   STRUCT
run_viol viol_bad_size  STRUCT
run_viol viol_cav_parent I1
run_viol viol_raise_dead I4
run_viol viol_decay_proc DECAY
run_viol viol_casc_out_dead I1
run_viol viol_med_suffix STRUCT
run_viol viol_med_cell  I2
run_viol viol_med_issuer I2
run_viol viol_probe     STRUCT
run_viol viol_mem       STRUCT
run_viol viol_after_ret STRUCT
run_viol viol_struct_misc STRUCT
run_viol viol_unterm_proc STRUCT
run_viol viol_unterm_casc STRUCT
run_viol viol_nested_proc STRUCT
run_viol viol_casc_noinput STRUCT
run_viol viol_casc_op   STRUCT
run_viol viol_jump_unknown STRUCT
run_viol viol_dup_label DUP
run_viol viol_imm       STRUCT
run_viol viol_casc_med  STRUCT
run_viol viol_dup_proc  DUP
run_viol viol_casc_header STRUCT
run_viol viol_casc_suffix STRUCT
run_viol viol_acasc_out STRUCT
run_viol viol_proc_header STRUCT
# Переполнение смещений и коллизии host API.
run_viol viol_mem_overflow STRUCT
run_viol viol_host_boot   STRUCT
run_viol viol_host_prefix STRUCT tests/viol_host_prefix.stderr
run_viol viol_cav_proc    DUP
run_viol viol_med_gdup    DUP tests/viol_med_gdup.stderr
run_lib lib_hello
run_lib lib_typed
run_lib lib_result
run_lib lib_boot_fault
run_lib lib_sync_fault
run_lib lib_view_reconstruct
run_lib_compile crc32c_name_collision
run_lib_compile lib_scope
run_lib_compile lib_fault_name
run_lib lib_abort
run_lib lib_raise
run_lib lib_async
run_lib lib_async_boot
run_lib lib_async_fault
run_async_mutants
run_cli_contract
run_lsp_smoke
run_ownership_fuzz
run_execution_oracle
run_numeric8_oracle
run_numeric16_oracle
run_numeric32_oracle
run_numeric64_oracle
run_fault_smoke
run_proc_contracts
run_contract_fuzz
run_deterministic_artifacts
run_tiny_budgets
run_fuzz
if [ "${OS:-}" != "Windows_NT" ] || rza_cc_is_msvc; then
    run_benchmark_sources
fi
run_c3_unit
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
EXPECTED_PASS=305
if [ -n "${RZA_TARGET_ARCH:-}" ]; then
    case ${RZA_TARGET_EXPECTED_PASS:-} in
        ''|*[!0-9]*)
            echo "FATAL: RZA_TARGET_EXPECTED_PASS must be a decimal integer" >&2
            exit 2
            ;;
    esac
    EXPECTED_PASS=$RZA_TARGET_EXPECTED_PASS
fi
if [ "${OS:-}" = "Windows_NT" ] && ! rza_cc_is_msvc; then EXPECTED_PASS=304; fi
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
    echo "FAIL pass count: got $PASS, want $EXPECTED_PASS"
    exit 1
fi
exit 0
