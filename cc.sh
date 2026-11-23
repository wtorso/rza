#!/usr/bin/env bash
set -o nounset

rza_cc_is_msvc() {
    case "${CC:-cc}" in
        cl|cl.exe|*/cl|*/cl.exe|*\\cl|*\\cl.exe) return 0 ;;
        *) return 1 ;;
    esac
}

rza_target_tools_check() {
    local arch=$1 launcher_text=$2 expected_qemu base
    local -a launcher
    case "$arch" in
        aarch64) expected_qemu=qemu-aarch64 ;;
        riscv64) expected_qemu=qemu-riscv64 ;;
        *) echo "FATAL: unsupported target architecture: $arch" >&2; return 2 ;;
    esac
    read -r -a launcher <<<"$launcher_text"
    if [ "${#launcher[@]}" -eq 0 ]; then
        echo "FATAL: empty target launcher" >&2
        return 2
    fi
    base=${launcher[0]##*/}
    case "$base" in
        "$expected_qemu"|"$expected_qemu-static") ;;
        *) echo "FATAL: launcher does not match $arch: $base" >&2; return 2 ;;
    esac
    if ! command -v "${launcher[0]}" >/dev/null 2>&1; then
        echo "FATAL: target launcher not found: ${launcher[0]}" >&2
        return 2
    fi
    if ! command -v readelf >/dev/null 2>&1; then
        echo "FATAL: readelf is required for target execution" >&2
        return 2
    fi
    if ! command -v awk >/dev/null 2>&1; then
        echo "FATAL: awk is required for target execution" >&2
        return 2
    fi
    if [ -n "${CC:-}" ] && ! command -v "${CC%% *}" >/dev/null 2>&1; then
        echo "FATAL: target compiler not found: ${CC%% *}" >&2
        return 2
    fi
}

rza_target_init() {
    local arch=${RZA_TARGET_ARCH:-}
    local launcher=${RZA_TARGET_LAUNCHER:-}
    local log=${RZA_TARGET_LOG:-}
    if [ -z "$arch" ] && [ -z "$launcher" ] && [ -z "$log" ]; then return 0; fi
    if [ -z "$arch" ] || [ -z "$launcher" ] || [ -z "$log" ]; then
        echo "FATAL: target arch, launcher and log are required together" >&2
        return 2
    fi
    case ${RZA_TARGET_EXPECTED_PASS:-} in
        *[!0-9]*)
            echo "FATAL: RZA_TARGET_EXPECTED_PASS must be a decimal integer" >&2
            return 2
            ;;
    esac
    rza_target_tools_check "$arch" "$launcher" || return
}

rza_cc_init() {
    local mode=${1:?usage: rza_cc_init sanitize|release [include-dir ...]}
    shift
    case "$mode" in
        sanitize|release) ;;
        *) echo "FATAL: unknown compiler mode: $mode" >&2; return 2 ;;
    esac
    CC=${CC:-cc}
    rza_target_init || return
    if [ -z "${CFLAGS:-}" ]; then
        if rza_cc_is_msvc; then
            CFLAGS="/nologo /std:clatest /W4 /WX /TC /fp:strict /fp:except-"
            if [ "$mode" = release ]; then CFLAGS+=" /O2"; fi
        else
            CFLAGS="-std=c23 -pedantic -Wall -Wextra -Werror"
            CFLAGS+=" -fno-fast-math -ffp-contract=off -fexcess-precision=standard"
            if [ "$mode" = sanitize ]; then
                CFLAGS+=" -fsanitize=undefined -fno-sanitize-recover=undefined"
            else
                CFLAGS+=" -O2"
            fi
        fi
        local directory
        for directory in "$@"; do
            if rza_cc_is_msvc; then directory=$(cygpath -m "$directory"); fi
            CFLAGS+=" -I $directory"
        done
    fi
    LDFLAGS="${LDFLAGS:-}"
    if [ "${OS:-}" = "Windows_NT" ]; then
        case "$CC" in
            *clang-cl*)
                case "$LDFLAGS" in
                    *"/ignore:4217"*) ;;
                    *) LDFLAGS+=" /link /ignore:4217" ;;
                esac
                ;;
            *clang*)
                local resource_dir
                resource_dir=$(cygpath -m -s "$($CC -print-resource-dir)")
                LDFLAGS="-L$resource_dir/lib/windows $LDFLAGS"
                case "$LDFLAGS" in
                    *"/ignore:4217"*) ;;
                    *) LDFLAGS+=" -Wl,/ignore:4217" ;;
                esac
                ;;
        esac
    fi
    RZA_CC_DRIVER="./cc.sh"
    if [ "${OS:-}" = "Windows_NT" ]; then
        RZA_CC_SHELL=$(cygpath -m "$(command -v bash)")
    else
        RZA_CC_SHELL="bash"
    fi
    export CC CFLAGS LDFLAGS RZA_CC_DRIVER RZA_CC_SHELL
}

rza_cc() {
    bash ./cc.sh "$@"
}

rza_run() {
    if [ -z "${RZA_TARGET_ARCH:-}" ]; then
        if [ -n "${RZA_TARGET_LAUNCHER:-}" ] || [ -n "${RZA_TARGET_LOG:-}" ]; then
            echo "FATAL: target launcher and log require target arch" >&2
            return 2
        fi
        "$@"
        return
    fi
    bash tests/support/target_run.sh "$@"
}

rza_cc_compile() {
    LDFLAGS="" rza_cc "$@"
}

rza_cc_msvc_args() {
    local -a translated=()
    local compile_only=0 output="" have_output=0 output_dir=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -I)
                translated+=("$1")
                shift
                if [ "$#" -eq 0 ]; then
                    echo "FATAL: missing argument for -I" >&2
                    return 2
                fi
                translated+=("$(cygpath -m "$1")")
                ;;
            -I?*) translated+=("-I$(cygpath -m "${1#-I}")") ;;
            -c) compile_only=1 ;;
            -o)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "FATAL: missing argument for -o" >&2
                    return 2
                fi
                output=$(cygpath -m "$1")
                have_output=1
                ;;
            -*) translated+=("$1") ;;
            *)
                if [ -e "$1" ]; then
                    translated+=("$(cygpath -m "$1")")
                else
                    translated+=("$1")
                fi
                ;;
        esac
        shift
    done
    if [ "$compile_only" -eq 1 ]; then translated+=(/c); fi
    if [ "$have_output" -eq 1 ]; then
        if [ "$compile_only" -eq 1 ]; then
            translated+=("/Fo$output")
        else
            output_dir=${output%/*}
            if [ "$output_dir" = "$output" ]; then output_dir=.; fi
            translated+=("/Fo$output_dir/")
            translated+=("/Fe$output")
        fi
    fi
    RZA_CC_ARGS=("${translated[@]}")
}

rza_cc_execute() {
    if rza_cc_is_msvc; then
        rza_cc_msvc_args $CFLAGS $LDFLAGS "$@"
        # cl echoes source names and link progress; retain every actual diagnostic.
        MSYS2_ARG_CONV_EXCL='*' $CC "${RZA_CC_ARGS[@]}" 2>&1 \
            | sed -E -e '/^[^()]*\.c\r?$/d' -e '/^Generating Code\.\.\.\r?$/d' >&2
        return "${PIPESTATUS[0]}"
    fi
    $CC $CFLAGS $LDFLAGS "$@"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
set -euo pipefail
rza_cc_execute "$@"
