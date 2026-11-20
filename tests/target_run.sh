#!/usr/bin/env bash
set -o nounset
export LC_ALL=C

fail() {
    printf 'TARGET_LAUNCHER: %s\n' "$2" >&2
    exit "$1"
}

arch=${RZA_TARGET_ARCH:-}
launcher_text=${RZA_TARGET_LAUNCHER:-}
log=${RZA_TARGET_LOG:-}
if [ -z "$arch" ] || [ -z "$launcher_text" ] || [ -z "$log" ]; then
    fail 2 "arch, launcher and log are required"
fi
case "$arch" in
    aarch64)
        expected_machine=AArch64
        ;;
    riscv64)
        expected_machine=RISC-V
        ;;
    *) fail 2 "unsupported architecture: $arch" ;;
esac
. ./cc.sh
rza_target_tools_check "$arch" "$launcher_text" || fail 2 "invalid target configuration"
read -r -a launcher <<<"$launcher_text"
if [ "$#" -eq 0 ]; then fail 2 "missing executable"; fi
program=$1
if [ ! -f "$program" ] || [ ! -x "$program" ]; then
    fail 1 "not an executable: $program"
fi
if ! touch "$log"; then fail 2 "cannot write target log: $log"; fi
if ! header=$(readelf -h "$program" 2>/dev/null); then
    fail 1 "not an ELF executable: $program"
fi
class=$(awk -F: '/Class:/ {gsub(/^[[:space:]]+/, "", $2); print $2}' <<<"$header")
data=$(awk -F: '/Data:/ {gsub(/^[[:space:]]+/, "", $2); print $2}' <<<"$header")
machine=$(awk -F: '/Machine:/ {gsub(/^[[:space:]]+/, "", $2); print $2}' <<<"$header")
if [ "$class" != ELF64 ]; then fail 1 "not ELF64: $program ($class)"; fi
case "$data" in
    *"little endian"*) ;;
    *) fail 1 "not little-endian: $program ($data)" ;;
esac
if [ "$machine" != "$expected_machine" ]; then
    fail 1 "wrong machine for $arch: $machine"
fi
if ! printf '%s %s %s\n' "$arch" "$machine" "$program" >>"$log"; then
    fail 2 "cannot append target log: $log"
fi
exec "${launcher[@]}" "$@"
