#!/usr/bin/env python3
# 163 детерминированных случая: exit 0/1 и точные limit-диагностики.
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


def check(
    exe, path, failures, emit=False, diagnostic=None,
    expect_success=False, max_output_bytes=None,
):
    command = [exe, str(path)]
    if emit:
        command += ["--emit-c", "-o", str(path.with_suffix(".c"))]
    try:
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE if diagnostic or expect_success else subprocess.DEVNULL,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        failures.append(f"timeout: {path.read_text()!r}")
        return
    if expect_success:
        if result.returncode != 0:
            failures.append(f"emit failed: exit {result.returncode}: {result.stderr!r}")
        elif max_output_bytes is not None:
            output_bytes = path.with_suffix(".c").stat().st_size
            if output_bytes > max_output_bytes:
                failures.append(f"output {output_bytes} exceeds {max_output_bytes}")
        return
    if diagnostic:
        if result.returncode != 1 or diagnostic not in result.stderr:
            failures.append(f"missing {diagnostic!r}: exit {result.returncode}")
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
            text = "\n".join(
                rng.choice(TOKENS) for _ in range(rng.randrange(1, 40))
            )
            path.write_text(text)
            check(EXE, path, failures)
        deep = ["cav f0, field"]
        deep.extend(f"cav f{i}, f{i - 1}" for i in range(1, 4000))
        deep.extend(["decay f0", "ret"])
        path.write_text("\n".join(deep) + "\n")
        check(EXE, path, failures, emit=True, expect_success=True)
        reverse = ["cav f0, field"]
        reverse.extend(f"cav f{i}, f{i - 1}" for i in range(1, 4000))
        reverse.extend(f"decay f{i}" for i in range(3999, -1, -1))
        reverse.append("ret")
        path.write_text("\n".join(reverse) + "\n")
        # Each frame has fixed declarations and one enter/decay pair: 512 bytes suffices.
        check(
            EXE, path, failures, emit=True, expect_success=True,
            max_output_bytes=4000 * 512,
        )
        path.write_text(";" * 1048577)
        check(EXE, path, failures, diagnostic=b"source exceeds 1048576 bytes")
        path.write_text("\n".join(["mov %r0, 1"] * 16385))
        check(EXE, path, failures, diagnostic=b"too many instructions")
        # Four setup instructions plus 16,380 moves fill NODE_MAX before endc.
        cascade_cap = [
            "cav m, field",
            "res x, m, 8",
            "med x_m, x, m",
            "casc c: x_m -> out[m]",
        ]
        cascade_cap.extend(["mov %r0, 1"] * 16380)
        cascade_cap.append("endc")
        path.write_text("\n".join(cascade_cap) + "\n")
        check(EXE, path, failures, diagnostic=b"too many instructions")
    if failures:
        print("\n".join(failures[:5]), file=sys.stderr)
        return 1
    print("FUZZ OK (165 cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
