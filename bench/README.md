# RZA benchmarks

These scripts compare concrete RZA workloads with C and Rust implementations.
They are measurement tools, not evidence that one language is universally faster
or safer than another.

## Requirements

- `bench/run.sh` requires Linux; `bench/check.sh` also supports Windows MSVC.
- The RZA build requirements from the repository README.
- A C23 compiler and `rustc`; full measurement also needs `objdump`, `awk`, and `date`.
- The timer uses `clock_gettime(CLOCK_MONOTONIC)` on POSIX and
  `QueryPerformanceCounter` on Windows.

Windows Zig benchmark checks stop at Rust static-library linking because Zig
compiler-rt and Rust compiler-builtins define duplicate weak symbols. CI retains
the previous 204-check scope rather than forcing duplicate-symbol resolution.

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

The RZA call, ring, parser, and protocol variants use minimal typed `ro`/`rw`
procedure contracts. Static contract checking is part of every build; expected
outputs and attack variants remain identical to their legacy equivalents.

- CRC32C processes 4096 deterministic input bytes with the reflected Castagnoli
  polynomial. It compares RZA inside a cascade, RZA with a lifetime check on each
  byte, portable C, portable Rust, and a Rust SSE4.2 intrinsic implementation.
  A separate table-driven variant uses the same 256-entry table in RZA, C, and
  Rust. RZA builds its table during `rza_boot`, C during preparation, and Rust at
  compile time; all initialization is outside the timed region. The intrinsic
  version detects CPU support at runtime and records whether it used hardware or
  the software fallback. The RZA `crc32c` variant processes 512 64-bit words and
  reports the same backend labels; its bitwise fallback is tested independently.
  A separate RZA variant explicitly unrolls eight words; assembly inspection
  requires eight hardware CRC instructions in its specialized procedure.
- The table workload performs 1024 requests against 512 open-addressed
  key/value slots. A second variant fills every slot and requires all versions
  to return the same full-table result instead of reading a missing entry.
- The ring workload performs 1024 push/pop requests with four slots, wraparound,
  and full/empty rejection. Its digest includes popped values and both rejection
  counts; RZA, C, and Rust use the same `push ×5 / pop ×3` pattern.
- The parser workload runs a start/key/value state machine over 4096 patterned
  bytes. Checked numeric accumulation, invalid transitions, and the final digest
  are identical in RZA, C, and Rust.
- The protocol workload parses variable-length binary frames with checked offsets,
  sequence recovery, a 1024-byte payload quota, a four-slot ring with backpressure,
  and CRC32C over zero-padded eight-byte payloads. Bounded payload views avoid
  a scratch copy: full words are loaded directly and short words are assembled in
  a register with zero high bytes. The mixed input exercises malformed
  lengths, bad sequences and bad CRCs. Quota, truncated-input, and initial-length-attack
  variants run during correctness checks on all three implementations. RZA uses its
  `crc32c` opcode with runtime feature detection; C and Rust use the portable bitwise
  implementation here, so backend labels differ and these are not intrinsic-only timings.
  The digest is `crc_sum + accepted*1000 + invalid*1000000 + dropped*1000000000 +
  truncated*1000000000000 + quota*1000000000000000`. In mixed/quota/truncated/attack
  order, the accepted counts are 207/128/454/206, invalid counts 234/0/0/244, dropped
  counts 135/82/299/134, truncated counts 0/0/1/0, quota counts 1/1/0/1, and CRC sums
  142667339200, 94053616594, 326184563651, and 163532088806. These components derive
  the four checked-in expected outputs.
- The checked-arithmetic pair runs 1024 identical RZA iterations with wrapping or
  checked `add/sub/mul/inc/dec`. Dynamic cell inputs prevent constant folding;
  both variants must return zero. On x86-64, inspection requires `jo` in the
  checked path and rejects it in the wrapping path. This measures both overflow
  branches and optimizations lost when faults are observable, including loop
  collapse; it is not an isolated instruction-latency benchmark.
- The call workload performs 1024 wrapping updates and returns digest 3072. It
  compares an RZA driver making direct internal calls, direct calls to the exported
  ABI from C, and calls to the same exported ABI through a volatile function pointer.
  The host is a separate translation unit from generated C. Both ABI loops disable
  unrolling; on x86-64, inspection requires one direct or indirect work-call site.
  Direct versus indirect ABI isolates indirection; internal versus exported calls
  also includes driver, frame lifecycle, and loop differences. Each timed step also
  includes one reset and the final mediator/digest read, so `ns/step` is the complete
  1024-update workload, not the latency of one call.
- The async pair executes 1024 tasks and checks 1024 completions per step. The
  single-callback variant resets state and completed cells for every task; the queue
  variant performs 128 resets with eight FIFO tasks each. Their digest is 2048. Timing
  includes reset, enqueue, drain, mediator reads, and frame lifecycle; `ns/task` is not
  isolated indirect branch latency. Each cascade reuses its fixed OUT allocation with
  a fresh allocation generation. Single-callback programs use a specialized direct
  drain, while programs with multiple callbacks retain the generic queue drain.
  Inspection checks both shapes.

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

## Compile-time scaling

`bash bench/compile_scaling.sh` generates bounded synthetic programs in
`build/compile-scaling` and measures 64, 128, 256, 512, and 1024 legacy procedures,
equivalent `rw`-contracted procedures, or async cascades. It records transpile time and
source/artifact sizes for all three shapes, plus C23 backend time for both procedure
shapes. Override `RZA_SCALING_COUNTS`,
`RZA_SCALING_REPEATS`, `RZA_SCALING_BACKEND_REPEATS`, `RZA_SCALING_BUILD`, or set
`RZA_SCALING_BACKEND=0` for a frontend-only run. These measurements detect scaling
regressions; they do not establish a universal runtime or compile-time advantage.

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
