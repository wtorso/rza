#!/usr/bin/env bash
# run_tests.sh — полный прогон REZ3-ASM: сборка транспайлера (C3), трансляция,
# компиляция C99 (-pedantic -Wall -Wextra, ноль warnings), UBSan, запуск и
# сверка exit/stdout, негативные тесты, LSP и fuzz. exit 0 только если всё зелёное.
set -u
cd "$(dirname "$0")"

# компилятор C99 для сгенерированного кода
if   command -v gcc   >/dev/null 2>&1; then CC="gcc"
elif command -v zig   >/dev/null 2>&1; then CC="zig cc"
elif command -v clang >/dev/null 2>&1; then CC="clang"
else echo "FATAL: no C compiler (gcc | zig | clang)" >&2; exit 2; fi

CFLAGS="-std=c99 -pedantic -Wall -Wextra -fsanitize=undefined "
CFLAGS+="-fno-sanitize-recover=undefined -I refs -I ."
BUILD=".test-build-$$"
rm -rf "$BUILD"
mkdir -p "$BUILD"
trap 'rm -rf "$BUILD"' EXIT

echo "== build rez3asm.exe (c3c) =="
bash build_compiler.sh
TR="./rez3asm.exe"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1 -- $2"; }

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
    if ! $CC $CFLAGS "$BUILD/$t.c" -o "$BUILD/$t.exe" \
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
    tr -d '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! diff -u "$dir/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        diff -u "$dir/$t.expected" "$BUILD/$t.out.lf"
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
    if ! $CC $CFLAGS "$BUILD/$t.c" -o "$BUILD/$t.exe" \
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
    if ! grep -q "$want" "$BUILD/$t.runerr"; then
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
    if ! grep -q "\[$rule\]" "$BUILD/$t.err"; then
        bad "$t" "no [$rule] in stderr"; cat "$BUILD/$t.err"
        return
    fi
    ok "$t"
}

# python3 на Windows может быть битым стабом WindowsApps — проверяем запуск.
run_py() {
    local name=$1 script=$2
    local py=""
    local c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then
            py="$c"; break
        fi
    done
    if [ -z "$py" ]; then
        bad "$name" "no working python3/python"; return
    fi
    if "$py" "$script" ./rez3asm.exe; then ok "$name"
    else bad "$name" "script failed"; fi
}

run_lsp_smoke() { run_py lsp_smoke tests/lsp_smoke.py; }
run_fuzz() { run_py fuzz tests/fuzz_smoke.py; }

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
    if ! $CC $CFLAGS "$BUILD/$t.lib.c" "$HARNESS" \
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
    tr -d '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! diff -u "tests/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        diff -u "tests/$t.expected" "$BUILD/$t.out.lf"
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
    if ! $CC $CFLAGS tests/runtime_safety.c -o "$BUILD/runtime_safety.exe" \
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

run_reference() {
    if ! $CC -std=c89 -pedantic -Wall -Wextra refs/rez3check.c \
            -o "$BUILD/rez3check.exe" 2>"$BUILD/rez3check.ccerr"; then
        bad reference "C89 compile failed"; cat "$BUILD/rez3check.ccerr"
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
    if ! grep -q "violations=0" "$BUILD/deep.ref.out"; then
        bad reference "unexpected violations"; cat "$BUILD/deep.ref.out"
        return
    fi
    ok reference
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
run_reference
run_build_parallel

# примеры учебника GUIDE.md — регрессия документации (аудит #3)
for t in hello counter2 idioms settle; do
    DIR=docs/examples run_good "$t"
done
run_dead dead_link "FAULT line 10: dead mediator acc_m"
run_dead ret_dead "FAULT line 8: dead mediator x_m"
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
run_fuzz
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
