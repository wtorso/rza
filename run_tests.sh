#!/usr/bin/env bash
# run_tests.sh — полный прогон REZ3-ASM: сборка транспайлера (C3), трансляция,
# компиляция C23 со строгими warnings, UBSan, запуск и сверка exit/stdout,
# негативные тесты, LSP и fuzz. exit 0 только если всё зелёное.
set -o nounset
cd "$(dirname "$0")"

# компилятор C23 для сгенерированного кода
if [ -z "${CC:-}" ]; then
    if   command -v gcc   >/dev/null 2>&1; then CC="gcc"
    elif command -v zig   >/dev/null 2>&1; then CC="zig cc"
    elif command -v clang >/dev/null 2>&1; then CC="clang"
    else echo "FATAL: no C compiler (gcc | zig | clang)" >&2; exit 2; fi
fi

if [ -z "${CFLAGS:-}" ]; then
    CFLAGS="-std=c23 -pedantic -Wall -Wextra -Werror -fsanitize=undefined "
    CFLAGS+="-fno-sanitize-recover=undefined -I refs -I ."
fi
# LNK4217 относится только к clang_rt.ubsan_standalone.lib, не к RZA objects.
LDFLAGS="${LDFLAGS:-}"
if [ "${OS:-}" = "Windows_NT" ]; then
    case "$CC" in
        *clang*) LDFLAGS+=" -Wl,/ignore:4217" ;;
    esac
fi
export CC CFLAGS LDFLAGS
BUILD=".test-build-$$"
rm --recursive --force "$BUILD"
mkdir --parents "$BUILD"
trap 'rm --recursive --force "$BUILD"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1 -- $2"; }

run_style() {
    local status
    if ! : >"$BUILD/style.out"; then
        bad style "cannot write style output"
        return
    fi
    git grep --untracked --line-number --perl-regexp '(*UTF).{101}' -- \
        '*.c3' '*.c' '*.h' '*.sh' '*.md' '*.rza' '*.expected' \
        '.gitignore' '.gitmodules' 'LICENSE' >"$BUILD/style.out" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        bad style "lines longer than 100"
        cat "$BUILD/style.out"
        return
    fi
    if [ "$status" -ne 1 ]; then
        bad style "git grep failed"
        cat "$BUILD/style.out"
        return
    fi
    ok style
}
run_style

run_function_style() {
    local c3c_bin="c3c"
    if ! command -v "$c3c_bin" >/dev/null 2>&1; then
        c3c_bin="$LOCALAPPDATA/c3/c3c.exe"
    fi
    if ! "$c3c_bin" compile tests/runner.c3 tests/harness.c3 \
            tests/function_length.c3 tests/deterministic_artifacts.c3 \
            tests/tiny_budgets.c3 tests/fuzz_smoke.c3 tests/ownership_model.c3 \
            tests/ownership_fuzz.c3 tests/lsp_client.c3 tests/fault_scenarios.c3 \
            tests/fault_smoke.c3 tests/lsp_smoke.c3 tests/lsp_memory_posix.c3 \
            tests/lsp_memory_win32.c3 -o "$BUILD/rza_tests" \
            >"$BUILD/function_style.out" 2>&1; then
        bad function_style "C3 test runner build failed"
        cat "$BUILD/function_style.out"
        return
    fi
    if [ -f "$BUILD/rza_tests" ]; then
        mv "$BUILD/rza_tests" "$BUILD/rza_tests.exe" || return
    fi
    if ! "$BUILD/rza_tests.exe" function-style >>"$BUILD/function_style.out" 2>&1; then
        bad function_style "function length or scanner error"
        cat "$BUILD/function_style.out"
        return
    fi
    ok function_style
}
run_function_style

echo "== build rez3asm.exe (c3c) =="
bash build_compiler.sh
TR="./rez3asm.exe"

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
    if ! $CC $CFLAGS $LDFLAGS "$BUILD/$t.c" -o "$BUILD/$t.exe" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    if ! "./$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "runtime failed (want exit 0)"; cat "$BUILD/$t.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! diff --unified "$dir/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        diff --unified "$dir/$t.expected" "$BUILD/$t.out.lf"
        return
    fi
    ok "$t"
}

# Runtime-fault: exit != 0 и точная диагностика $2 (или FAULT).
run_dead() {
    local t=${1:-dead_link}
    local want=${2:-FAULT}
    if ! $TR "tests/$t.rza" --emit-c -o "$BUILD/$t.c" \
            2>"$BUILD/$t.trerr"; then
        bad "$t" "transpile failed (want exit 0: runtime-fault is legal)"
        cat "$BUILD/$t.trerr"
        return
    fi
    if ! $CC $CFLAGS $LDFLAGS "$BUILD/$t.c" -o "$BUILD/$t.exe" \
            2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    if "./$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "exited 0 (want runtime fault)"
        return
    fi
    if ! grep --quiet "$want" "$BUILD/$t.runerr"; then
        bad "$t" "missing diagnostic: $want"; cat "$BUILD/$t.runerr"
        return
    fi
    ok "$t"
}

# незаконная программа: транспайлер exit 1, stderr содержит [$2]
run_viol() {
    local t=$1 rule=$2
    if $TR "tests/$t.rza" >"$BUILD/$t.out" \
            2>"$BUILD/$t.err"; then
        bad "$t" "transpiler accepted invalid program (want exit 1)"
        return
    fi
    if ! grep --quiet "\[$rule\]" "$BUILD/$t.err"; then
        bad "$t" "no [$rule] in stderr"; cat "$BUILD/$t.err"
        return
    fi
    ok "$t"
}

run_c3() {
    local name=$1 command=$2
    if "$BUILD/rza_tests.exe" "$command"; then ok "$name"
    else bad "$name" "C3 scenario failed"; fi
}

run_lsp_smoke() { run_c3 lsp_smoke lsp; }
run_fuzz() { run_c3 fuzz fuzz; }
run_ownership_fuzz() { run_c3 ownership_fuzz ownership; }
run_fault_smoke() { run_c3 fault_smoke faults; }
run_deterministic_artifacts() { run_c3 deterministic_artifacts artifacts; }
run_tiny_budgets() { run_c3 tiny_budgets budgets; }

run_c3_unit() {
    local c3c_bin="c3c"
    if ! command -v "$c3c_bin" >/dev/null 2>&1; then
        c3c_bin="$LOCALAPPDATA/c3/c3c.exe"
    fi
    if ! "$c3c_bin" compile-test rez3asm.c3 compiler/model.c3 \
            compiler/checker.c3 compiler/emitter.c3 lsp_server.c3 \
            memory_guard.c3 scratch_memory.c3 tests/output_writer_test.c3 \
            tests/memory_guard_test.c3 tests/checker_budget_test.c3 \
            tests/function_length.c3 tests/function_length_test.c3 \
            -o "$BUILD/c3_tests" >"$BUILD/c3_tests.log" 2>&1; then
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
    if ! $CC $CFLAGS $LDFLAGS "$BUILD/$t.lib.c" "$HARNESS" \
            -o "$BUILD/$t.exe" 2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    if ! "./$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"; then
        bad "$t" "runtime failed (want exit 0)"; cat "$BUILD/$t.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! diff --unified "tests/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        diff --unified "tests/$t.expected" "$BUILD/$t.out.lf"
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
    if ! $CC $CFLAGS -c "$BUILD/$t.lib.c" -o "$BUILD/$t.lib.o" \
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

run_runtime_safety() {
    if ! $CC $CFLAGS $LDFLAGS tests/runtime_safety.c -o "$BUILD/runtime_safety.exe" \
            2>"$BUILD/runtime_safety.ccerr"; then
        bad runtime_safety "compile failed"; cat "$BUILD/runtime_safety.ccerr"
        return
    fi
    if [ -s "$BUILD/runtime_safety.ccerr" ]; then
        bad runtime_safety "compiler warnings (want zero)"
        cat "$BUILD/runtime_safety.ccerr"
        return
    fi
    if ! "$BUILD/runtime_safety.exe"; then
        bad runtime_safety "runtime checks failed"
        return
    fi
    ok runtime_safety
}

run_shop() {
    if ! $CC $CFLAGS $LDFLAGS refs/shop.c -o "$BUILD/shop.exe" \
            2>"$BUILD/shop.ccerr"; then
        bad shop "compile failed"; cat "$BUILD/shop.ccerr"
        return
    fi
    if ! "$BUILD/shop.exe" >"$BUILD/shop.out" 2>"$BUILD/shop.runerr"; then
        bad shop "runtime failed"; cat "$BUILD/shop.runerr"
        return
    fi
    tr --delete '\r' <"$BUILD/shop.out" >"$BUILD/shop.out.lf"
    if ! diff --unified tests/shop.expected "$BUILD/shop.out.lf"; then
        bad shop "stdout mismatch"
        return
    fi
    ok shop
}

run_reference() {
    if ! $CC $CFLAGS $LDFLAGS refs/rez3check.c \
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
    if ! "$BUILD/rez3check.exe" "$BUILD/deep.rz3" >"$BUILD/deep.ref.out"; then
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
    if ! "$BUILD/rez3check.exe" "$BUILD/raise_old.ref.rz3" \
            >"$BUILD/raise_old.ref.out"; then
        bad reference "live mediator rejected after raise"; cat "$BUILD/raise_old.ref.out"
        return
    fi
    if ! grep --quiet "violations=0" "$BUILD/raise_old.ref.out"; then
        bad reference "unexpected raise violations"; cat "$BUILD/raise_old.ref.out"
        return
    fi
    ok reference
}

check_ref_reject() {
    local name=$1 expected=$2 status
    "$BUILD/rez3check.exe" >"$BUILD/$name.out"
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
    ok reference_invalid
}

run_build_parallel() {
    local p1 p2 status
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
    ok build_parallel
}

echo "== REZ3-ASM test run (compiler: $CC) =="
for t in fib counter back_button cascade indexed decay_subtree casc_out_med \
         mangle_label mangle_proc mangle_cav no_cells unaligned; do
    run_good "$t"
done
run_good imm_bounds
run_good arith_wrap
run_good compare_edges
run_good skipped_decay
run_good cav_reuse
run_dead cav_reentry "FAULT line 3: frame allocation f"
run_dead raise_home "FAULT line 9: dead mediator x_m"
run_dead bounds_dynamic "FAULT line 6: out of bounds x_m"
run_dead bounds_casc_dynamic "FAULT line 7: out of bounds x_m"
run_dead div_zero "FAULT line 3: division"
run_dead div_overflow "FAULT line 4: division"
run_dead mod_overflow "FAULT line 4: division"
run_dead shift_range "FAULT line 2: shift"
run_dead shift_negative "FAULT line 3: shift"
run_viol viol_bounds_imm STRUCT
run_viol viol_bounds_negative STRUCT
run_viol viol_aligned_size STRUCT
run_viol viol_res_sum_overflow STRUCT
run_viol viol_cap_out_overflow STRUCT
run_viol viol_frame_static_budget STRUCT
run_viol viol_total_static_budget STRUCT
run_runtime_safety
run_shop
run_reference
run_reference_invalid
run_build_parallel

# примеры учебника GUIDE.md — регрессия документации (аудит #3)
for t in hello counter2 idioms settle shop; do
    DIR=docs/examples run_good "$t"
done
run_dead dead_link "FAULT line 10: dead mediator acc_m"
run_dead ret_dead "FAULT line 8: dead mediator x_m"
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
run_viol viol_host_prefix STRUCT
run_viol viol_cav_proc    DUP
run_viol viol_med_gdup    DUP
run_lib lib_hello
run_lib_compile lib_scope
run_lib lib_abort
run_lib lib_raise
$TR tests/fib.rza tests/counter.rza >"$BUILD/cli_two.out" 2>"$BUILD/cli_two.err"
if [ "$?" -ne 2 ]; then
    bad cli_two_inputs "want exit 2 for two input files"
else
    ok cli_two_inputs
fi
run_lsp_smoke
run_ownership_fuzz
run_fault_smoke
run_deterministic_artifacts
run_tiny_budgets
run_fuzz
run_c3_unit
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
