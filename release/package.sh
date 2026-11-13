#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

release_target() {
    local os_name arch
    case "$(uname -s)" in
        Linux) os_name=linux ;;
        MINGW*|MSYS*|CYGWIN*) os_name=windows ;;
        *) echo "FATAL: unsupported release OS: $(uname -s)" >&2; return 2 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        *) echo "FATAL: unsupported release architecture: $(uname -m)" >&2; return 2 ;;
    esac
    printf '%s-%s\n' "$os_name" "$arch"
}

stage_sources() {
    local root=$1 file
    git ls-files -z --cached --others --exclude-standard |
        while IFS= read -r -d '' file; do
            if [ ! -f "$file" ]; then continue; fi
            mkdir --parents "$root/$(dirname "$file")"
            cp -p "$file" "$root/$file"
        done
}

write_release() {
    local root=$1 version=$2 target=$3 commit=$4 dirty=$5
    printf '%s\n' "RZA_VERSION=$version" "RZA_COMMIT=$commit" \
        "RZA_TARGET=$target" "C3_VERSION=0.8.5_1" "RZA_DIRTY=$dirty" \
        >"$root/RELEASE"
}

version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' project.json)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "FATAL: invalid project version: $version" >&2
    exit 2
fi
target=$(release_target)
commit=$(git rev-parse HEAD)
dirty=0
if [ -n "$(git status --porcelain)" ]; then
    if [ "${RZA_RELEASE_ALLOW_DIRTY:-0}" != 1 ]; then
        echo "FATAL: release source is dirty; set RZA_RELEASE_ALLOW_DIRTY=1 to allow" >&2
        exit 2
    fi
    dirty=1
fi

if command -v c3c >/dev/null 2>&1; then C3C="c3c"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/c3/c3c.exe" ]; then
    C3C="$LOCALAPPDATA/c3/c3c.exe"
else echo "FATAL: no c3c" >&2; exit 2; fi
c3_version=$($C3C --version | sed -n 's/^C3 Compiler Version:[[:space:]]*//p')
if [ "$c3_version" != "0.8.5_1" ]; then
    echo "FATAL: C3 0.8.5_1 is required, found $c3_version" >&2
    exit 2
fi

out=${RZA_RELEASE_OUT:-$PWD/build/release}
mkdir --parents "$out"
out=$(cd "$out" && pwd -P)
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm --recursive --force "$stage"' EXIT
package="rza-$version-$target"
root="$stage/$package"
mkdir --parents "$root"
stage_sources "$root"
write_release "$root" "$version" "$target" "$commit" "$dirty"

compiler="rez3asm"
if [ "${OS:-}" = "Windows_NT" ]; then compiler="rez3asm.exe"; fi
bash build_compiler.sh >"$out/build.log" 2>&1
cp -p "$compiler" "$root/$compiler"
chmod 0755 "$root/$compiler"
chmod -R u=rwX,go=rX "$root"
tar --sort=name --format=ustar --owner=0 --group=0 --numeric-owner \
    --mtime="@0" -cf "$out/$package.tar" -C "$stage" "$package"
gzip -n -9 -f "$out/$package.tar"
printf '%s\n' "$out/$package.tar.gz"
