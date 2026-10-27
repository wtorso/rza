#!/usr/bin/env python3
# 161 детерминированный случай: допустимы только exit 0/1, без crash/timeout.
import random
import subprocess
import sys
import tempfile
from pathlib import Path

EXE = sys.argv[1] if len(sys.argv) > 1 else "./rez3asm.exe"
SEED = """cav main, field
res x, main, 16
med x_m, x, main
mov %r0, 42
store [x_m + 0], %r0
load %r1, [x_m + 0]
print %r1
decay main
ret
"""
TOKENS = [
    "cav main, field", "res x, main, 16", "med x_m, x, main",
    "load %r0, [x_m + 0]", "store [x_m + 0], %r0", "print %r0",
    "proc worker:", "casc c: x_m -> out[field]", "acasc c: x_m -> out",
    "endc", "ret", "decay main", "jmp nowhere", "label:", "mov %r0, 1",
    "add %r1, %r0, 2", "loadb %r0, [x_m + 1]", "raise x, field",
    "cav", "", "; comment", "out[field]junk", "%r99", "2147483648",
]


def check(exe, path, failures, emit=False):
    command = [exe, str(path)]
    if emit:
        command += ["--emit-c", "-o", str(path.with_suffix(".c"))]
    try:
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=3,
        )
    except subprocess.TimeoutExpired:
        failures.append(f"timeout: {path.read_text()!r}")
        return
    if result.returncode not in (0, 1):
        failures.append(f"exit {result.returncode}: {path.read_text()!r}")


def main():
    rng = random.Random(0x5EED)
    failures = []
    with tempfile.TemporaryDirectory(prefix="rez3-fuzz-") as tmp:
        path = Path(tmp) / "case.rza"
        for _ in range(80):
            text = SEED
            for _ in range(rng.randrange(1, 8)):
                pos = rng.randrange(len(text) + 1)
                if rng.randrange(2):
                    text = text[:pos] + rng.choice("[]%,:+-x09\n") + text[pos:]
                else:
                    text = text[:pos] + text[pos + 1:]
            path.write_text(text)
            check(EXE, path, failures)
        for _ in range(80):
            path.write_text("\n".join(rng.choice(TOKENS) for _ in range(rng.randrange(1, 40))))
            check(EXE, path, failures)
        deep = ["cav f0, field"]
        deep.extend(f"cav f{i}, f{i - 1}" for i in range(1, 4000))
        deep.extend(["decay f0", "ret"])
        path.write_text("\n".join(deep) + "\n")
        check(EXE, path, failures, emit=True)
    if failures:
        print("\n".join(failures[:5]), file=sys.stderr)
        return 1
    print("FUZZ OK (161 cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
