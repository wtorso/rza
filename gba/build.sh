#!/usr/bin/env bash
# build.sh — сборка программы .rza в GBA ROM:
#   ./build.sh ../tests/fib.rza out/fib.gba
# Конвейер: rez3asm --emit-c → zig cc (arm-freestanding, ARMv4T) →
# линковка с crt0/harness (zig cc как линкер) → elf → objcopy → .gba.
set -eu
cd "$(dirname "$0")"
mkdir -p out

T="${1:-../tests/fib.rza}"
BASE=$(basename "$T" .rza)
OUT="${2:-out/$BASE.gba}"

if [ ! -x ../rez3asm.exe ] || [ ../rez3asm.c3 -nt ../rez3asm.exe ] \
        || [ ../lsp_server.c3 -nt ../rez3asm.exe ]; then
    C3C="$HOME/AppData/Local/c3/c3c.exe"
    # сборка в .new + замена через rename: VS Code держит rez3asm.exe (LSP)
    "$C3C" compile ../rez3asm.c3 ../lsp_server.c3 -o ../rez3asm.new || exit 2
    if ! mv -f ../rez3asm.new.exe ../rez3asm.exe 2>/dev/null; then
        rm -f ../rez3asm.old.exe 2>/dev/null
        mv -f ../rez3asm.exe ../rez3asm.old.exe \
            && mv -f ../rez3asm.new.exe ../rez3asm.exe || exit 2
    fi
    mv -f ../rez3asm.new.pdb ../rez3asm.pdb 2>/dev/null
fi

../rez3asm.exe "$T" --emit-c -o "out/$BASE.c"
# --emit-c даёт main; ROM использует его как есть.
zig cc -target arm-freestanding-eabi -mcpu=arm7tdmi -std=c99 -O2 \
    -fno-stack-protector -fno-sanitize=all -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -I include -I ../refs -I .. \
    -c crt0.c -o out/crt0.o
zig cc -target arm-freestanding-eabi -mcpu=arm7tdmi -std=c99 -O2 \
    -fno-stack-protector -fno-sanitize=all -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c harness.c -o out/harness.o
zig cc -target arm-freestanding-eabi -mcpu=arm7tdmi -std=c99 -O2 \
    -fno-stack-protector -fno-sanitize=all -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -I include -I ../refs -I .. \
    -c "out/$BASE.c" -o "out/$BASE.o"
zig cc -target arm-freestanding-eabi -mcpu=arm7tdmi -nostdlib \
    -Wl,-T,gba.ld \
    out/crt0.o out/harness.o "out/$BASE.o" -o "out/$BASE.elf"
zig objcopy -O binary "out/$BASE.elf" "$OUT"
echo "OK $OUT"
