#!/usr/bin/env bash
# run_tests.sh — полный прогон REZ3-ASM: сборка транспайлера (C3), трансляция,
# компиляция C99 (-pedantic -Wall -Wextra, ноль warnings), запуск, сверка,
# негативные тесты. exit 0 только если всё зелёное.
set -u
cd "$(dirname "$0")"

# компилятор C3 для транспайлера
if   command -v c3c >/dev/null 2>&1; then C3C="c3c"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/c3/c3c.exe" ]; then
    C3C="$LOCALAPPDATA/c3/c3c.exe"
else echo "FATAL: no c3c" >&2; exit 2; fi

# компилятор C99 для сгенерированного кода
if   command -v gcc   >/dev/null 2>&1; then CC="gcc"
elif command -v zig   >/dev/null 2>&1; then CC="zig cc"
elif command -v clang >/dev/null 2>&1; then CC="clang"
else echo "FATAL: no C compiler (gcc | zig | clang)" >&2; exit 2; fi

CFLAGS="-std=c99 -pedantic -Wall -Wextra -I refs -I ."
BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD"

# шаг 0: сборка транспайлера
echo "== build rez3asm.exe (c3c) =="
if ! $C3C compile rez3asm.c3 lsp_server.c3 -o rez3asm; then
    echo "FATAL: transpiler build failed" >&2
    exit 2
fi
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
    "./$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"
    tr -d '\r' <"$BUILD/$t.out" >"$BUILD/$t.out.lf"
    if ! diff -u "$dir/$t.expected" "$BUILD/$t.out.lf" >/dev/null 2>&1; then
        bad "$t" "stdout mismatch"
        diff -u "$dir/$t.expected" "$BUILD/$t.out.lf"
        return
    fi
    ok "$t"
}

# runtime-fault ($1, по умолчанию dead_link): транслируется и
# компилируется, при запуске exit!=0 и FAULT в stderr
run_dead() {
    local t=${1:-dead_link}
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
    if ! grep -q "FAULT" "$BUILD/$t.runerr"; then
        bad "$t" "no FAULT in stderr"; cat "$BUILD/$t.runerr"
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

# LSP smoke: сессия initialize/didOpen/didOpen/shutdown с `rez3asm --lsp`
# по stdio (tests/lsp_smoke.py). python3 на Windows может быть битым стабом
# WindowsApps — проверяем, что интерпретатор реально запускается.
run_lsp_smoke() {
    local py=""
    local c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then
            py="$c"; break
        fi
    done
    if [ -z "$py" ]; then
        bad "lsp_smoke" "no working python3/python"; return
    fi
    if "$py" tests/lsp_smoke.py ./rez3asm.exe; then ok lsp_smoke
    else bad lsp_smoke "script failed"; fi
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
    if [ -f "tests/$t.harness.c" ]; then HARNESS="tests/$t.harness.c"; else HARNESS="tests/lib_harness.c"; fi
    if ! $CC $CFLAGS "$BUILD/$t.lib.c" "$HARNESS" \
            -o "$BUILD/$t.exe" 2>"$BUILD/$t.ccerr"; then
        bad "$t" "compile failed"; cat "$BUILD/$t.ccerr"
        return
    fi
    if [ -s "$BUILD/$t.ccerr" ]; then
        bad "$t" "compiler warnings (want zero)"; cat "$BUILD/$t.ccerr"
        return
    fi
    "./$BUILD/$t.exe" >"$BUILD/$t.out" 2>"$BUILD/$t.runerr"
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

echo "== REZ3-ASM test run (compiler: $CC) =="
for t in fib counter back_button cascade indexed decay_subtree casc_out_med \
         mangle_label mangle_proc mangle_cav no_cells; do
    run_good "$t"
done

# примеры учебника GUIDE.md — регрессия документации (аудит #3)
for t in hello counter2 idioms settle; do
    DIR=docs/examples run_good "$t"
done
run_dead
run_dead ret_dead
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
# review #6/#7 + покрытие веток чекера (review #12)
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
run_viol viol_acasc_out STRUCT
run_viol viol_proc_header STRUCT
# review-audit: переполнение смещения [med + off] (#3) + коллизии имён
# с host API lib-режима (#4)
run_viol viol_mem_overflow STRUCT
run_viol viol_host_boot   STRUCT
run_viol viol_host_prefix STRUCT
run_viol viol_cav_proc    DUP
run_viol viol_med_gdup    DUP
run_lib lib_hello
run_lib_compile lib_scope
run_lib lib_abort
run_lsp_smoke
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
