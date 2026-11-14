#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
sysroot=$(rustc --print sysroot)

json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

printf '%s' '{"kind":"finished","buildfile":"'
json_string "$script_dir/${0##*/}"
printf '%s' '","project":{"sysroot":"'
json_string "$sysroot"
printf '%s' '","sysroot_src":"'
json_string "$sysroot/lib/rustlib/src/rust/library"
printf '%s' '","crates":['
separator=
for source in "$root"/bench/*.rs; do
    [ -f "$source" ] || continue
    name=${source##*/}
    name=${name%.rs}
    printf '%s{"display_name":"%s","root_module":"%s",' \
        "$separator" "$(json_string "$name")" "$(json_string "$source")"
    printf '%s' '"edition":"2021","deps":[],"is_workspace_member":true}'
    separator=,
done
printf ']}}\n'
