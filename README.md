# RZA

[Русская версия](README.ru.md)

RZA is a low-level language and intermediate representation with explicit memory
lifetimes, checked memory access, and assembly-like control flow. Source files
use the `.rza` extension. The `rez3asm` compiler validates them and generates
C23, leaving native optimization and instruction selection to the C toolchain.

RZA is intended for small kernels that benefit from fixed memory budgets and
defined fault behavior, not for hiding low-level programming behind a high-level
syntax. Version [0.3.0](https://github.com/wtorso/rza/releases/tag/v0.3.0) is a
prerelease; the language and host interfaces can still change.

## Requirements

Building from source requires [C3
0.8.5_1](https://github.com/c3lang/c3c/releases/tag/v0.8.5_1) with `c3c` in
`PATH`, a C23 compiler (GCC, Clang, Zig, or MSVC on Windows), Bash, and standard
command-line tools. Running a packaged compiler does not require C3, but compiling
its C23 output still requires a C compiler. Rust is optional when building or using the
compiler, but the complete test suite requires `rustc` for its comparison programs and
benchmark checks.

The commands below use a POSIX-compatible shell. CI also builds and tests the
project on Windows with Bash, Zig, and MSVC. Release packages are currently provided
only for Linux x86_64 and Windows x86_64. The Windows binary uses the dynamic
Microsoft C runtime (`VCRUNTIME140.dll`) and `dbghelp.dll`; static CRT is not
included.

## Build and run

Clone the repository and build the compiler:

```sh
git clone https://github.com/wtorso/rza.git
cd rza
bash build_compiler.sh
```

The build script writes `./build/bin/rez3asm` on POSIX and
`./build/bin/rez3asm.exe` on Windows.
Compile and run the included standalone example:

```sh
mkdir -p build
./build/bin/rez3asm examples/hello.rza --emit-c -o build/hello.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello
./build/hello
```

Expected output:

```text
41
```

### Generated programs on Linux ARM64 and RV64

The `rez3asm` executable remains an x86_64 host compiler. Its C23 output can be
cross-compiled for little-endian Linux AArch64 and RV64; the C3 compiler itself is
not ported to those architectures. No public target-selection option is added to
the RZA CLI.

The validated configuration is:

- Zig 0.17.1 with Clang 22.1.8 as the cross-compiler.
- `aarch64-linux-musl`: little-endian LP64, static musl, no external sysroot,
  launched with `/usr/bin/qemu-aarch64-static` and no `-L` prefix.
- `riscv64-linux-musl`: little-endian LP64D, static musl, no external sysroot,
  launched with `/usr/bin/qemu-riscv64-static` and no `-L` prefix.
- QEMU 11.1.3 and `readelf` for execution and architecture checks.

For example, starting from the same `build/hello.c`:

```sh
zig cc -target aarch64-linux-musl -std=c23 -O2 -static \
  -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello-arm64
qemu-aarch64-static build/hello-arm64

zig cc -target riscv64-linux-musl -std=c23 -O2 -static \
  -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/hello.c -o build/hello-rv64
qemu-riscv64-static build/hello-rv64
```

Both programs print `41`. On non-x86 targets, SSE4.2 and other x86-only paths are
compiled out; CRC32C uses the portable fallback with independently known vectors.
No ARM CRC acceleration is claimed.

The internal test runner also supports a paired architecture and launcher setting.
For example:

```sh
CC="zig cc -target aarch64-linux-musl -static" \
RZA_TARGET_ARCH=aarch64 \
RZA_TARGET_LAUNCHER=qemu-aarch64-static \
RZA_TARGET_LOG="$PWD/build/target-aarch64.exec.log" \
RZA_TARGET_EXPECTED_PASS=192 \
bash run_tests.sh
```

For RV64, use `riscv64`, `riscv64-linux-musl`, `qemu-riscv64-static`, and a separate
log path. Every target executable is checked centrally for ELF64, little-endian, and
the required machine ID before QEMU execution. Missing settings or tools are an
infrastructure failure, never a fallback to host execution.

The validated target run has `PASS=192` and 1211 logged executions on each target.
The log includes mutation and shrink attempts, so 1211 is not a semantic test count.
It includes the numeric8, numeric16, numeric32, and numeric64 oracles, each with 64
valid + 64 fault programs, and 75 direct RZA workload checks. It also includes nine
numeric8 shrink-signature executions added after the original platform baseline. C3/compiler
internals, LSP, static diagnostics, deterministic artifacts, release/package checks,
native Rust comparisons, and timing are host-only or separate native gates; they are
not counted as ARM/RV64 execution evidence.

These results cover cross-build and QEMU user-mode validation only. They do not cover
real hardware, big-endian targets, other libc implementations or ABIs, ARM32, RV32,
or cross-target ASan/UBSan, and do not establish performance. Release archives still
contain only the x86_64 host compiler; no ARM/RV64 compiler assets are created.

### Validate without generating C

```sh
./build/bin/rez3asm examples/hello.rza
```

A valid program produces no output and exits with status 0. Invalid input prints
`VIOLATION` diagnostics and exits with status 1. Command-line usage errors and
file I/O failures exit with status 2.

## Command-line interface

```text
rez3asm file.rza [--emit-c | --emit-lib] [-o file.c]
rez3asm --lsp
rez3asm --help
rez3asm --version
```

- With no output flag, the compiler performs validation only.
- `--emit-c` generates a standalone C program with `main`.
- `--emit-lib` generates a C library without `main`, for use by a C host.
- `-o` writes generated C to a file and enables generation even without an emit
  flag. Without `-o`, generated C is written to standard output.
- `--lsp` starts the language server on standard input and output.
- Sole `--help` prints usage and exits 0; no arguments prints it to stderr and
  exits 2. Sole `--version` prints `rez3asm 0.3.0` and exits 0.

`build_compiler.sh` creates the compiler but does not install it into `PATH`;
invoke it by its path or use the installer below.

## Install and release packages

### User-local installation

From a source checkout:

```sh
PREFIX="$HOME/.local" bash install.sh
export PATH="$HOME/.local/bin:$PATH"
```

`PREFIX` defaults to `/usr/local`; `DESTDIR` is available for staged installs.
The installer never invokes sudo. It copies the native compiler, both runtime
headers, and the license. When compiling generated C after installation, add
`-I "$HOME/.local/include/rza"` to the C compiler flags.

From an extracted binary package, avoid rebuilding with C3 by selecting its
compiler explicitly:

```sh
RZA_COMPILER=./rez3asm PREFIX="$HOME/.local" bash install.sh
```

### Binary archives

Download the desired archive and `SHA256SUMS` from the
[0.3.0 release](https://github.com/wtorso/rza/releases/tag/v0.3.0), then verify
and extract it. `--ignore-missing` lets you download only one platform archive:

```sh
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf rza-0.3.0-linux-x86_64.tar.gz
cd rza-0.3.0-linux-x86_64
./rez3asm --version
```

The archive contains the native compiler, runtime headers, source, tests,
benchmarks, and examples. The quickstart above also works from this directory.
`RELEASE.txt` records the version, full source commit, target, C3 version, and
`RZA_DIRTY=0`. Packages are built in two clean checkouts and must be
byte-identical before they can be published. Checksums verify integrity; they are not a signature.

## Memory and execution

Programs use sixteen 64-bit registers, `%r0` through `%r15`, as bit containers.
Each instruction defines how their bits are interpreted. Memory is organized into
cells and is never addressed through a raw pointer in RZA code.

- `field` is the root frame and lives for the whole program.
- `cav name, parent` creates a frame that owns a fixed-size memory arena.
- `res cell, frame, size` reserves a zero-initialized cell in a live frame.
- `med ref, cell, frame` creates a checked reference called a mediator.
  Generation checks prevent a stale mediator from referring to reused storage.
- `decay frame` invalidates the frame and all of its descendants. Later access
  through an affected mediator produces a runtime `FAULT`.
- `raise cell, ancestor` changes ownership only for static checking. It does not
  move memory or extend the lifetime of the original frame. The home frame must
  remain alive for any access.
- `casc ... endc` checks all input mediators before executing a block. If an
  input is dead at runtime, the whole block is skipped with `ABORT`; its output
  is an 8-byte cell.
- `acasc ... endc` enqueues work in a bounded cooperative FIFO. `await` drains
  the queue and returns the number of successful tasks. This is not OS-thread
  parallelism or network asynchronous I/O.

RZA combines static validation with defined runtime outcomes. Statically
detectable ownership errors and constant out-of-bounds accesses produce
`VIOLATION`. Dead mediators, dynamic out-of-bounds accesses, invalid arithmetic,
and exhausted runtime resources produce `FAULT`. A cascade with a dead input
skips its body with `ABORT`. These checks do not prove application logic and do
not cover raw pointers, offsets, or lifetimes manipulated by a C host.

Procedures start with clean registers. Values are exchanged through cells, not
parameter registers or a return register. Recursion is rejected.

A parenthesized procedure header optionally declares its mediator capabilities:

```asm
proc convert(input_m: ro, result_m: rw):
```

The names refer to existing global mediators and their cell layouts. `ro` permits
reads, probes, views and cascade inputs; `rw` also permits stores. Access through
an unlisted mediator and new mediator declarations inside a contracted procedure
are static violations. Local views inherit the source capability. A global view is
a separate mediator: listing its source does not list the view. A contracted caller
must expose every capability required by its callee and cannot escalate `ro` to
`rw`, including through a call chain. Empty `proc pure():` contracts allow no
mediator access. Legacy `proc name:` headers are unchanged. Contracts hold at most
64 mediators and erase completely before C generation. Access diagnostics name the
procedure; call failures also name the direct callee.

`add`, `sub`, `mul`, `inc`, and `dec` wrap modulo 2^64. Their checked variants
`cadd`, `csub`, `cmul`, `cinc`, and `cdec` instead produce `FAULT` on signed
overflow. Checked arithmetic does not enforce application rules such as a
nonnegative quota; those still need explicit validation. `shr` is an arithmetic
right shift; `ushr` is a logical right shift. Division by zero, overflowing
signed division or remainder, and invalid shift counts produce `FAULT`. A
constant out-of-bounds access is rejected during validation; a
register-dependent out-of-bounds access is a runtime `FAULT`.

### 8-bit, 16-bit, 32-bit, and 64-bit typed operations

The `.i8`, `.u8`, `.i16`, `.u16`, `.i32`, `.u32`, `.i64`, and `.u64` suffixes
select signed or unsigned semantics for `mov`, `load`, `store`, `add`, `sub`,
`mul`, `inc`, `dec`, `cadd`, `csub`, `cmul`, `cinc`, `cdec`, `and`, `or`, `xor`,
`div`, `mod`, `shl`, and `ushr`. Signed types also support `shr` and `slt`;
unsigned types support `ult`. Each width has 43 operation/type spellings, for 172
in total. Floating point and invalid operation/type pairs remain rejected. Legacy
`loadb`/`storeb` remain aliases only for `load.u8`/`store.u8`.

Typed operations read only the low 8, 16, 32, or 64 bits of their register operands.
Signed results sign-extend and unsigned results zero-extend into the 64-bit
register. Typed stores write exactly that low-width bit pattern; 64-bit values use
the full container. A layout field requires the exact matching load/store type.
Raw cells retain byte offsets; typed cells use element indices. Fields have
alignment 2 for 16-bit, 4 for 32-bit, and 8 for 64-bit types. Raw multi-byte
accesses may be unaligned and use defined byte copies (`memcpy` in the C23 output),
never narrow pointer casts. Byte accesses use defined unsigned-char loads and
stores. Memory uses target byte order, not a portable wire format.

Tests place independent canaries around raw stores and next to 32-bit and 64-bit
layout fields; generated C must copy exactly two, four, or eight bytes,
respectively. Async tests print a checked 32-bit result directly in the callback
and after a result load, and prove that a 64-bit checked overflow prevents callback
output, result stores, and async OUT publication.

Wrapping arithmetic is modulo 256, 65536, 4294967296, or 2^64. Checked arithmetic
faults outside -128..127, -32768..32767, -2147483648..2147483647, or
-9223372036854775808..9223372036854775807 for signed operations, and 0..255,
0..65535, 0..4294967295, or 0..18446744073709551615 for unsigned operations.
Signed division truncates toward zero; zero divisors and signed minimum / -1 fault
for both division and remainder. Unsigned division and remainder fault only on
zero. Shift counts are 0..7, 0..15, 0..31, or 0..63: `shl` discards high bits,
signed `shr` fills the sign bit, and `ushr` fills zeroes.

Decimal literals use those same signed and unsigned ranges. Any leading minus on
an unsigned literal, including `-0`, is rejected. Typed hex ranges are
`0x0`..`0xff`, `0x0`..`0xffff`, `0x0`..`0xffffffff`, and
`0x0`..`0xffffffffffffffff`; leading zeroes are allowed. Negative hex is rejected
except for typed i64 value immediates, which retain the legacy compatibility rule.
Shift-count immediates use legacy i64 parsing, including negative hex, and negative
counts become a runtime shift fault. `print` remains signed i64 output, including
for u64 values above INT64_MAX.

`crc32c DST, STATE, WORD` updates CRC32C over the eight little-endian bytes of
`WORD`. Initial and final XOR remain explicit. The runtime uses SSE4.2 when the
CPU supports it and otherwise produces the same result through a bitwise fallback.

The runtime uses fixed storage. After initialization it does not call `malloc`,
`realloc`, or `free`.

## Bounded views

`view DST, SOURCE, OFFSET, LENGTH` creates a mediator for a subrange of an
existing mediator without allocating or copying cell data:

```asm
view payload_m, input_m, %r2, %r3
loadb %r0, [payload_m + %r1]
```

Offsets and lengths are bytes for raw cells and elements for typed cells. Each
operand can be an `i64` immediate or a register. Negative or impossible constant
ranges are `VIOLATION`; dynamic failures and dead sources are `FAULT`. An
immediate length fixes the destination extent for static access checks even when
the offset or parent extent is dynamic. Dynamic lengths retain runtime bounds
checks. Empty views, including one at the end of a cell, are valid; nested views
cannot widen their parent.

Views inherit owner, home, lifetime, and generation checks. Host-created
mediators must contain valid aligned metadata and describe the actual object
extent. The runtime checks arithmetic and metadata consistency but cannot
validate arbitrary non-null C addresses. Async OUT cells reuse
their fixed eight bytes on each enqueue and advance a per-allocation generation,
so stale mediators and views cannot observe a later publication as if it were
the old one. Create views at top level, in procedures, or inside synchronous cascades.
Block-local views are visible only within that cascade. Async cascade bodies do
not construct views; both cascade forms accept preconstructed views as inputs.

## Typed layouts

Flat records describe field widths, alignment, and element counts:

```asm
layout Entry: key:i64, value:i64
res entries, field, Entry[2]
med entries_m, entries, field

mov %r0, 0
mov %r1, 42
store [entries_m + %r0].key, %r1
store [entries_m + %r0].value, %r1
load %r2, [entries_m + 0].value
print %r2
ret
```

The value after `+` is an element index for a typed cell, not a byte offset. The
compiler calculates the record stride and field offsets from each type's width and
alignment. Use legacy `load`/`store` for `i64` fields and the exactly matching
`load`/`store` suffix for `u8`, `i8`, `u16`, `i16`, `u32`, or `i32` fields. The
`loadb`/`storeb` aliases remain available only for `u8`. Raw cells use byte offsets
and have no field selector.

See [the ring buffer example](examples/ring_buffer.rza) for typed state, an array
of records, and fixed-capacity index arithmetic.

## Embedding in C

Generate a library and link it with the included host:

```sh
./build/bin/rez3asm examples/shop.rza --emit-lib -o build/shop.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I include/rza -I . \
  build/shop.c examples/shop_host.c -o build/shop_host
./build/shop_host
```

The host exits with status 0 after `rza_boot` runs the shop program. Its output
matches `examples/shop.expected` and ends with `DEAD` because the final `probe`
observes the decayed cart frame. The library exports `rza_boot`, procedure entry
points, frame and mediator accessors, `rza_deref_cell`, `rza_arena_alloc`, and
`rza_await`.

The host ABI version is 5. Rebuild all C translation units against the same
headers and generated code. RZA checks do not make arbitrary host C safe: the
host remains responsible for its own pointers, offsets, and object lifetimes.

`rza_boot` is single-shot and returns an `RzaResult`. Repeated boots and reentry
from a diagnostic callback return `RZA_FAULT_ENTRY_STATE`. Exported procedures
also return `RzaResult`; their implicit frames are closed on success and fault,
so they may be called again. `rza_await` returns `RzaAwaitResult` with the
completed count and result. Any `FAULT` cancels queued tasks and clears their
pending flags; completed writes remain, and cancelled OUT cells are not published.

Standalone programs print the diagnostic and exit 1 on `FAULT`. A generated
library instead returns the first fault code and source line without exiting or
printing by default. Install `rza_set_diagnostic_handler` to receive diagnostics.
There is no transactional rollback: writes completed before the fault remain
visible and the host must repair or discard application state as appropriate.

## Examples and editors

- [hello](examples/hello.rza): the smallest runnable program.
- [ring_buffer](examples/ring_buffer.rza): a bounded FIFO with typed state and
  full/empty rejection, including wraparound.
- [shop](examples/shop.rza): state transitions and embedding in a C host.

Each example has an adjacent `.expected` file where its output is applicable.
The [VS Code extension](https://github.com/wtorso/rza-vscode) provides syntax
highlighting, diagnostics, hover, definitions, references, and context-aware
completion through the real language server. Rename supports layouts, fields,
frames, cells, mediators, and procedures, uses versioned edits, and is returned
only when the renamed program passes the checker. Since each `.rza` file is a
self-contained program, navigation and rename stay within the current document;
labels are not included. Lightweight modes for
[Emacs and Neovim](https://github.com/wtorso/rza-editors) provide syntax
highlighting without requiring the compiler.

## Benchmarks

On Linux, with `rustc` and `objdump` installed, run:

```sh
bash bench/run.sh
```

The benchmarks compare CRC32C, hash-table, ring-buffer, parser, and protocol workloads
in RZA, C, and Rust, with additional RZA-only call and async dispatch measurements.
Compile and runtime costs are recorded separately, and disassembly is saved.
See [the benchmark guide](bench/README.md) for toolchain selection, output files,
and measurement limits. Results apply only to the recorded machine, toolchain,
and workload; they do not establish a universal advantage over C or Rust.

## Current limits

- Only flat `u8`/`i8`/`u16`/`i16`/`u32`/`i32`/`u64`/`i64` records and fixed-size
  arrays are supported. Nested and packed layouts, unions, bitfields, and a portable
  wire ABI are not implemented.
- The fixed-width integer core covers 8-, 16-, 32-, and 64-bit operations. Stage 2
  completion requires final numeric64 acceptance; floating point and Stage 3 have not
  started.
- There are no OS threads, garbage collection, recursion, physical memory moves,
  transactional rollback, or general-purpose networking primitives.
- RZA has no general SIMD or intrinsic interface and no native optimizing backend.
  The fixed `crc32c` opcode uses runtime feature detection and has a portable
  fallback. The selected C23 compiler performs other target-specific code generation.
- Fixed budgets make resource limits explicit; they do not resize automatically.
- The checker does not prove application logic correct or sanitize host C.

## Verify

Build and run the complete suite:

```sh
bash build_compiler.sh
bash run_tests.sh
```

Expected results are `PASS=305 FAIL=0` on POSIX and Windows MSVC, and
`PASS=304 FAIL=0` on Windows Zig. Benchmark correctness checks require `rustc`
and run on POSIX and Windows MSVC. Windows Zig retains its previous scope because
Rust static-library linking conflicts with Zig compiler-rt weak symbols; do not mask it
with `FORCE:MULTIPLE`. The full timing script `bench/run.sh` remains Linux-only; MSVC runs
correctness and timer tests.

Other supported compiler selections are:

```sh
CC=clang bash run_tests.sh
CC="zig cc" RUST_CC=clang bash run_tests.sh
CC=cl bash run_tests.sh
```

`CC=cl` selects Microsoft `cl.exe` and requires Git Bash inside the x64 Native
Tools environment for Visual Studio 2022 with a Windows SDK. `cc.sh` supplies
`/std:clatest`, `/W4`, `/WX`, and `/TC`; `clang-cl` is a different frontend and
is not a substitute for this check. MSVC does not provide GCC-compatible UBSan,
so sanitizer coverage remains with GCC, Clang, and Zig. Windows Zig remains
supported with its existing UBSan and packaging checks.

`RUST_CC` selects the linker for Rust static libraries; it does not replace the
C compiler used for generated RZA code. CI runs Linux GCC/Clang/Zig, Windows Zig,
Windows MSVC `cl.exe`, Linux AArch64/RV64 QEMU target jobs, and VS Code unit,
packaging, Extension Host, and production-dependency checks. Linux Clang additionally
runs the full suite with ASan and UBSan. Linux GCC and both Windows compilers also
verify reproducible packages and staged installation. The Release workflow supports
manual dry runs and publication from version tags.

## Repository layout

- `src/`: CLI, language server, language model, layouts, checker, C23 emitter,
  and compiler memory helpers.
- `include/rza/`: public fixed-storage C23 runtime headers.
- `build/bin/`: ignored native compiler output.
- `install.sh`: native compiler/header installation with `PREFIX` and `DESTDIR`.
- `release/`: reproducible packaging, smoke checks, and release notes.
- `examples/`: focused runnable examples and expected output.
- `tests/`: positive, negative, runtime, ABI, LSP, fuzz, and style checks.
- `tests/reference/`: C23 reference checker and static reference program.
- `bench/`: comparable workloads, timing, and disassembly checks.
- `editors/vscode`: VS Code extension as a separate submodule.

## License

RZA is available under the [MIT License](LICENSE).
