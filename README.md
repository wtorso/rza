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

The build script writes `./rez3asm` on POSIX and `rez3asm.exe` on Windows in the
repository root.
Compile and run the included standalone example:

```sh
mkdir -p build
./rez3asm examples/hello.rza --emit-c -o build/hello.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I refs -I . \
  build/hello.c -o build/hello
./build/hello
```

Expected output:

```text
41
```

### Validate without generating C

```sh
./rez3asm examples/hello.rza
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
  move memory or extend the lifetime of the original frame.
- `casc ... endc` checks all input mediators before executing a block. If an
  input is dead at runtime, the whole block is skipped with `ABORT`; its output
  is an 8-byte cell.
- `acasc ... endc` enqueues work in a bounded cooperative FIFO. `await` drains
  the queue and returns the number of successful tasks. This is not OS-thread
  parallelism or network asynchronous I/O.

Procedures start with clean registers. Values are exchanged through cells, not
parameter registers or a return register. Recursion is rejected.

`add`, `sub`, `mul`, `inc`, and `dec` wrap modulo 2^64. Division by zero,
overflowing signed division or remainder, and invalid shift counts produce
`FAULT`. A constant out-of-bounds access is rejected during validation; a
register-dependent out-of-bounds access is a runtime `FAULT`.

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

See [the complete typed example](examples/typed_layout.rza) for arrays, padding,
and byte truncation.

## Embedding in C

Generate a library and link it with the included host:

```sh
./rez3asm examples/shop.rza --emit-lib -o build/shop.c
${CC:-cc} -std=c23 -O2 -pedantic -Wall -Wextra -Werror -I refs -I . \
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

- [hello](examples/hello.rza): cells, mediators, arithmetic, and output.
- [counter2](examples/counter2.rza): procedure calls and shared field storage.
- [idioms](examples/idioms.rza): comparisons and branches without CPU flags.
- [settle](examples/settle.rza): a synchronous cascade over two cells.
- [shop](examples/shop.rza): a longer state-transition example.
- [typed_layout](examples/typed_layout.rza): typed records and byte fields.

Each example has an adjacent `.expected` file where its output is applicable.
The [VS Code extension](https://github.com/wtorso/rza-vscode) provides syntax
highlighting and diagnostics through the real language server. Lightweight
modes for [Emacs and Neovim](https://github.com/wtorso/rza-editors) provide
syntax highlighting without requiring the compiler.

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
- RZA has no direct SIMD/intrinsics or native optimizing backend. The selected
  C23 compiler performs optimization and target-specific code generation.
- Fixed budgets make resource limits explicit; they do not resize automatically.
- The checker does not prove application logic correct or sanitize host C.

## Verify

Build and run the complete suite:

```sh
bash build_compiler.sh
bash run_tests.sh
```

Expected results are `PASS=156 FAIL=0` on POSIX and `PASS=155 FAIL=0` on Windows.
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
Linux GCC and Windows also verify reproducible packages and staged installation.
The Release workflow supports manual dry runs and publication from version tags.

## Repository layout

- `compiler/`: language model, layouts, checker, and C23 emitter.
- `rez3asm.c3`, `lsp_server.c3`: CLI and language server.
- `memory_guard.c3`, `scratch_memory.c3`: compiler memory limits and ownership.
- `install.sh`: native compiler/header installation with `PREFIX` and `DESTDIR`.
- `release/`: reproducible packaging, smoke checks, and release notes.
- `examples/`: runnable examples and expected output.
- `tests/`: positive, negative, runtime, ABI, LSP, fuzz, and style checks.
- `bench/`: comparable workloads, timing, and disassembly checks.
- `refs/`: shared fixed-storage C23 runtime and reference tools.
- `editors/vscode`: VS Code extension as a separate submodule.

## License

RZA is available under the [MIT License](LICENSE).
