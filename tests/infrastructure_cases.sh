#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

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
