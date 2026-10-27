#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"

if   command -v c3c >/dev/null 2>&1; then C3C="c3c"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/c3/c3c.exe" ]; then
    C3C="$LOCALAPPDATA/c3/c3c.exe"
else echo "FATAL: no c3c" >&2; exit 2; fi

NEW="rez3asm.$$.new"
OLD="rez3asm.$$.old"
trap 'rm -f "$NEW.exe" "$NEW.pdb" "$OLD.exe" "$OLD.pdb" 2>/dev/null || true' EXIT

if ! $C3C compile rez3asm.c3 lsp_server.c3 -o "$NEW"; then
    echo "FATAL: transpiler build failed" >&2
    exit 2
fi
# VS Code может держать текущий exe: сначала переименовываем его.
if ! mv -f "$NEW.exe" rez3asm.exe 2>/dev/null; then
    rm -f "$OLD.exe" 2>/dev/null
    mv -f rez3asm.exe "$OLD.exe" \
        && mv -f "$NEW.exe" rez3asm.exe \
        || { echo "FATAL: cannot replace rez3asm.exe" >&2; exit 2; }
fi
mv -f "$NEW.pdb" rez3asm.pdb 2>/dev/null
