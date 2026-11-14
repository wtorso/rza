# RZA benchmarks

These scripts compare concrete RZA workloads with C and Rust implementations.
They are measurement tools, not evidence that one language is universally faster
or safer than another.

## Requirements

- Linux; the timer uses `clock_gettime(CLOCK_MONOTONIC)`.
- The RZA build requirements from the repository README.
- A C23 compiler, `rustc`, `objdump`, `awk`, and `date`.

Run from the repository root:

```sh
bash bench/run.sh
```

Select another toolchain and keep its output separate:

```sh
CC=clang RZA_BENCH_BUILD=build/bench-clang bash bench/run.sh
CC="zig cc" RUST_CC=clang RZA_BENCH_BUILD=build/bench-zig bash bench/run.sh
```

`CC` compiles generated RZA C and the C comparison programs. `RUSTC` selects the
Rust compiler. `RUST_CC` selects the linker for Rust static libraries and defaults
to `CC`; the explicit Clang value above is for a GNU-target Rust static library
when RZA itself is built with Zig.

## Workloads and correctness

- CRC32C processes 4096 deterministic input bytes with the reflected Castagnoli
  polynomial. It compares RZA inside a cascade, RZA with a lifetime check on each
  byte, portable C, portable Rust, and a Rust SSE4.2 intrinsic implementation.
  A separate table-driven variant uses the same 256-entry table in RZA, C, and
  Rust. RZA builds its table during `rza_boot`, C during preparation, and Rust at
  compile time; all initialization is outside the timed region. The intrinsic
  version detects CPU support at runtime and records whether it used hardware or
  the software fallback. The RZA `crc32c` variant processes 512 64-bit words and
  reports the same backend labels; its bitwise fallback is tested independently.
- The table workload performs 1024 requests against 512 open-addressed
  key/value slots. A second variant fills every slot and requires all versions
  to return the same full-table result instead of reading a missing entry.
- The checked-arithmetic pair runs 1024 identical RZA iterations with wrapping or
  checked `add/sub/mul/inc/dec`. Dynamic cell inputs prevent constant folding;
  both variants must return zero. On x86-64, inspection requires `jo` in the
  checked path and rejects it in the wrapping path. This measures both overflow
  branches and optimizations lost when faults are observable, including loop
  collapse; it is not an isolated instruction-latency benchmark.

`bench/run.sh` first calls `bench/check.sh`. That script builds every variant,
compares output with the checked-in expected files, tests the full-table case,
and runs Rust workload tests and C timer tests. Timing does not start unless
these checks pass. Runtime steps also verify that every repeated result remains
unchanged.

## Measurements

The default settings are:

- `RZA_BENCH_COMPILE_REPEATS=20` compiler invocations;
- `RZA_BENCH_SAMPLES=11` timed runtime samples;
- `RZA_BENCH_BATCH=256` workload steps per sample.

Each setting must be a positive integer. Accepted ranges are 1–1000 compile
repeats, 1–101 samples, and 1–1000000 batch steps. Example of a shorter run:

```sh
RZA_BENCH_COMPILE_REPEATS=3 RZA_BENCH_SAMPLES=5 RZA_BENCH_BATCH=64 \
  bash bench/run.sh
```

Compile measurements include compiler process startup. RZA records transpilation,
C backend compilation, and the combined pipeline separately. C and Rust pipelines
include their respective complete compile/link commands.

Runtime preparation occurs outside the timed region. Two batches warm up each
workload, then samples are measured with a monotonic clock. Compile samples retain
collection order; runtime samples are sorted before reporting. Reports include
sample values, minimum, maximum, median, and a per-byte or per-step normalization.
Use medians and inspect variance before drawing conclusions.

## Output and disassembly

With the default build directory:

- `build/bench/results.txt` records the machine, compiler versions, flags,
  settings, timings, artifact sizes, and inspection results.
- `build/bench/asm/` contains disassembly for equivalent RZA, C, and Rust
  functions.
- On x86-64, hardware CRC runs are checked for an actual CRC instruction. A
  software fallback is labeled and is not presented as a hardware measurement.

`bench/safety/null_check.c` is a reduced model of the Linux v2.6.30
`tun_chr_poll` null-check issue. It is compiled only to compare normal C
optimization with `-fno-delete-null-pointer-checks`; the undefined function is
never executed. This illustrates a C compiler boundary, not a timed RZA workload
or a proof that all C or RZA programs are safe.

Compare results only with the recorded toolchain and workload. Measure again on
the target machine before making performance decisions.
