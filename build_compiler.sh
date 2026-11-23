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
        if [ "${OS:-}" = "Windows_NT" ]; then RELEASE_FLAGS+=(-z -Brepro); fi
        ;;
    *) echo "FATAL: RZA_RELEASE must be 0 or 1" >&2; exit 2 ;;
esac
BIN_DIR="${RZA_BUILD_DIR:-build/bin}"
mkdir --parents "$BIN_DIR"
TARGET="$BIN_DIR/rez3asm"
if [ "${OS:-}" = "Windows_NT" ]; then TARGET="$BIN_DIR/rez3asm.exe"; fi
NEW="$BIN_DIR/rez3asm.$$.new"
OLD="$BIN_DIR/rez3asm.$$.old"
trap 'rm --force "$NEW" "$NEW.exe" "$NEW.pdb" "$OLD.exe" "$OLD.pdb" \
    2>/dev/null || true' EXIT

if ! $C3C compile src/rez3asm.c3 src/compiler/model.c3 src/compiler/numeric.c3 \
        src/compiler/numeric_parse.c3 src/compiler/layout.c3 src/compiler/checker.c3 \
        src/compiler/float_emit.c3 src/compiler/emitter.c3 src/lsp/server.c3 \
        src/lsp/navigation.c3 src/lsp/completion.c3 src/lsp/references.c3 \
        src/memory_guard.c3 src/scratch_memory.c3 \
        -o "$NEW" "${RELEASE_FLAGS[@]}" \
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
    if ! mv --force "$NEW.pdb" "$BIN_DIR/rez3asm.pdb"; then
        echo "FATAL: cannot replace $BIN_DIR/rez3asm.pdb" >&2
        exit 2
    fi
else
    rm --force "$BIN_DIR/rez3asm.pdb"
fi
