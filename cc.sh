#!/usr/bin/env bash
set -o nounset

rza_cc_is_msvc() {
    case "${CC:-cc}" in
        cl|cl.exe|*/cl|*/cl.exe|*\\cl|*\\cl.exe) return 0 ;;
        *) return 1 ;;
    esac
}

rza_cc_init() {
    local mode=${1:?usage: rza_cc_init sanitize|release [include-dir ...]}
    shift
    case "$mode" in
        sanitize|release) ;;
        *) echo "FATAL: unknown compiler mode: $mode" >&2; return 2 ;;
    esac
    CC=${CC:-cc}
    if [ -z "${CFLAGS:-}" ]; then
        if rza_cc_is_msvc; then
            CFLAGS="/nologo /std:clatest /W4 /WX /TC"
            if [ "$mode" = release ]; then CFLAGS+=" /O2"; fi
        else
            CFLAGS="-std=c23 -pedantic -Wall -Wextra -Werror"
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
