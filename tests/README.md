# RZA test suite

Run the complete suite from the repository root:

```sh
bash build_compiler.sh
bash run_tests.sh
```

The root runner remains the public entry point. Source lists are explicit; do not replace them
with recursive file discovery. Test names, expected output, and host/target classifications stay
stable when files move.

## Directory guide

- `support/`: the C3 test runner, shared harness and style helpers, and shell/target
  infrastructure such as `target_run.sh` and `target_runner_cases.sh`.
- `unit/`: C3 `@test` unit tests for the compiler model, numeric descriptors, layouts, memory
  helpers, and source-style rules.
- `integration/`: compiler-level integration checks. It contains `lsp/`, `faults/`, `contracts/`,
  `deterministic_artifacts.c3`, `tiny_budgets.c3`, and `fuzz_smoke.c3`.
- `oracles/`: independent execution and ownership models plus numeric8, numeric16, numeric32,
  numeric64, and exact-rational float32/float64 differential oracles with closed coverage masks.
- `fixtures/`: RZA programs and their expected diagnostics or output, grouped by language area.
- `host/`: C drivers for public ABI, fault, canary, runtime-safety, and architecture-vector checks.
- `reference/`: the C23 reference checker and static reference program.

## Fixture categories

- `core/`: basic instructions, arithmetic, control flow, and standalone behavior.
- `ownership/`: frames, cells, mediators, lifetimes, and ownership transitions.
- `layouts/`: typed records, field access, element indices, and layout violations.
- `views/`: bounded views, dynamic extents, nested views, and view-specific failures.
- `cascades/`: synchronous cascade behavior and output handling.
- `async/`: cooperative asynchronous cascades, queueing, OUT publication, and async failures.
- `library/`: generated-library programs and their C harnesses.
- `diagnostics/`: static violations and exact compiler diagnostics.
- `numeric8/`, `numeric16/`, `numeric32/`, `numeric64/`: fixed-width typed operations, boundary
  cases, exact-width memory access, and checked-index contexts.

Every `.rza` source stays next to its applicable `.expected` and `.stderr` companions with the
same basename. Do not rename a fixture merely to change its category.

## Add or move a check

1. Choose the directory by responsibility, not by file extension alone.
2. Keep the logical test ID and companion files unchanged.
3. Register the source and every expected artifact explicitly in the applicable runner,
   `run_tests.sh`, `project.json`, or host harness.
4. Keep host-only checks separate from generated-program target evidence. C3/compiler internals,
   LSP, static diagnostics, deterministic artifacts, release/package checks, native Rust
   comparisons, and timing do not prove AArch64/RV64 execution.
5. For a new differential family, add closed coverage masks, known-answer checks, and deliberate
   mismatch detection. A non-empty corpus alone is not sufficient evidence.

Target execution logs include mutation and shrink attempts, so execution counts are not semantic
test counts. QEMU results do not imply real-hardware, big-endian, other-libc/ABI, or performance
claims.
