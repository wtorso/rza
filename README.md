# RZA

[Русская версия](README.ru.md)

RZA is a low-level language and intermediate representation with explicit memory
lifetimes, checked memory access, and assembly-like control flow. Source files
use the `.rza` extension. The `rez3asm` compiler validates them and generates
C23, leaving native optimization and instruction selection to the C toolchain.

RZA is intended for small kernels that benefit from fixed memory budgets and
defined fault behavior, not for hiding low-level programming behind a high-level
syntax. Version [0.1.0](https://github.com/wtorso/rza/releases/tag/v0.1.0) is a
prerelease; the language and host interfaces can still change.

## Requirements

Building from source requires [C3
0.8.5_1](https://github.com/c3lang/c3c/releases/tag/v0.8.5_1) with `c3c` in
`PATH`, a C23 compiler (GCC, Clang, or Zig), Bash, and standard command-line
tools. Running a packaged compiler does not require C3, but compiling its C23
output still requires a C compiler. Rust is optional and is used only for
comparison programs and benchmark checks.

The commands below use a POSIX-compatible shell. CI also builds and tests the
project on Windows with Bash and Zig. Release packages are currently provided
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
  exits 2. Sole `--version` prints `rez3asm 0.1.0` and exits 0.

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
[0.1.0 release](https://github.com/wtorso/rza/releases/tag/v0.1.0), then verify
and extract it. `--ignore-missing` lets you download only one platform archive:

```sh
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf rza-0.1.0-linux-x86_64.tar.gz
cd rza-0.1.0-linux-x86_64
./rez3asm --version
```

The archive contains the native compiler, runtime headers, source, tests,
benchmarks, and examples. The quickstart above also works from this directory.
`RELEASE.txt` records the version, full source commit, target, C3 version, and
`RZA_DIRTY=0`. Packages are built in two clean checkouts and must be
byte-identical before they can be published. Checksums verify integrity; they are not a signature.

## Memory and execution

Programs use sixteen signed 64-bit registers, `%r0` through `%r15`. Memory is
organized into cells and is never addressed through a raw pointer in RZA code.

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

`add`, `sub`, `mul`, `inc`, and `dec` wrap modulo 2^64. Their checked variants
`cadd`, `csub`, `cmul`, `cinc`, and `cdec` instead produce `FAULT` on signed
overflow. Checked arithmetic does not enforce application rules such as a
nonnegative quota; those still need explicit validation. `shr` is an arithmetic
right shift; `ushr` is a logical right shift. Division by zero, overflowing
signed division or remainder, and invalid shift counts produce `FAULT`. A
constant out-of-bounds access is rejected during validation; a
register-dependent out-of-bounds access is a runtime `FAULT`.

`crc32c DST, STATE, WORD` updates CRC32C over the eight little-endian bytes of
`WORD`. Initial and final XOR remain explicit. The runtime uses SSE4.2 when the
CPU supports it and otherwise produces the same result through a bitwise fallback.

The runtime uses fixed storage. After initialization it does not call `malloc`,
`realloc`, or `free`.

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
compiler calculates the record stride and field offsets. Use `load`/`store` for
`i64` fields and `loadb`/`storeb` for `u8` fields. Raw cells instead use byte
offsets and have no field selector.

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

The host ABI version is 4. Rebuild all C translation units against the same
headers and generated code. RZA checks do not make arbitrary host C safe: the
host remains responsible for its own pointers, offsets, and object lifetimes.

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

The benchmark compares equivalent CRC32C and hash-table workloads in RZA, C, and
Rust, records compile and runtime costs separately, and saves disassembly.
See [the benchmark guide](bench/README.md) for toolchain selection, output files,
and measurement limits. Results apply only to the recorded machine, toolchain,
and workload; they do not establish a universal advantage over C or Rust.

## Current limits

- Only flat `u8`/`i64` records and fixed-size arrays are supported. Nested and
  packed layouts, unions, bitfields, and a portable wire ABI are not implemented.
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

Expected results are `PASS=176 FAIL=0` on POSIX and `PASS=175 FAIL=0` on Windows.
The Windows suite excludes only the Linux-only benchmark-source checks. On Linux
the full suite also requires `rustc` for those checks.

Other supported compiler selections are:

```sh
CC=clang bash run_tests.sh
CC="zig cc" RUST_CC=clang bash run_tests.sh
```

`RUST_CC` selects the linker for Rust static libraries; it does not replace the
C compiler used for generated RZA code. CI runs Linux GCC/Clang/Zig, Windows Zig,
and VS Code unit, packaging, Extension Host, and production-dependency checks.
Linux Clang additionally runs the full suite with ASan and UBSan.
Linux GCC and Windows also verify reproducible packages and staged installation.
The Release workflow supports manual dry runs and publication from version tags.

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
