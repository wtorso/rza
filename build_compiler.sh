#!/usr/bin/env bash
set -o nounset
cd "$(dirname "$0")"

if   command -v c3c >/dev/null 2>&1; then C3C="c3c"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/c3/c3c.exe" ]; then
    C3C="$LOCALAPPDATA/c3/c3c.exe"
else echo "FATAL: no c3c" >&2; exit 2; fi

RELEASE_FLAGS=()
case "${RZA_RELEASE:-0}" in
    0) ;;
    1)
        RELEASE_FLAGS=(-g0)
        if [ "${OS:-}" = "Windows_NT" ]; then RELEASE_FLAGS+=(-z /Brepro); fi
        ;;
    *) echo "FATAL: RZA_RELEASE must be 0 or 1" >&2; exit 2 ;;
esac
TARGET="rez3asm"
if [ "${OS:-}" = "Windows_NT" ]; then TARGET="rez3asm.exe"; fi
NEW="rez3asm.$$.new"
OLD="rez3asm.$$.old"
trap 'rm --force "$NEW" "$NEW.exe" "$NEW.pdb" "$OLD.exe" "$OLD.pdb" \
    2>/dev/null || true' EXIT

if ! $C3C compile rez3asm.c3 compiler/model.c3 compiler/layout.c3 \
        compiler/checker.c3 compiler/emitter.c3 lsp_server.c3 memory_guard.c3 \
        scratch_memory.c3 -o "$NEW" "${RELEASE_FLAGS[@]}" \
        --validation=obnoxious \
        --warn-deadcode=error \
        --warn-recursivecontracts=error \
        --warn-methodvisibility=error \
        --warn-methodsnotresolved=error \
        --warn-deprecation=error \
        --warn-builtin=error \
        --warn-unusedparam=no \
        --warn-unusedlocal=no; then
    echo "FATAL: transpiler build failed" >&2
    exit 2
fi
if [ -f "$NEW" ] && [ ! -f "$NEW.exe" ]; then
    mv --force "$NEW" "$NEW.exe" \
        || { echo "FATAL: cannot normalize compiler output" >&2; exit 2; }
fi
# VS Code can hold the current executable, so move it aside first.
if ! mv --force "$NEW.exe" "$TARGET" 2>/dev/null; then
    rm --force "$OLD.exe" 2>/dev/null
    mv --force "$TARGET" "$OLD.exe" \
        && mv --force "$NEW.exe" "$TARGET" \
        || { echo "FATAL: cannot replace $TARGET" >&2; exit 2; }
fi
if [ -f "$NEW.pdb" ]; then
    if ! mv --force "$NEW.pdb" rez3asm.pdb; then
        echo "FATAL: cannot replace rez3asm.pdb" >&2
        exit 2
    fi
else
    rm --force rez3asm.pdb
fi
