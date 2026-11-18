module rza_tests;

import std::core::dstring;
import std::io;
import std::io::path;

alias ContractPredicate = fn bool(ContractWorld world);

fn bool contract_op_writes(ContractOpKind op) {
    return op == ContractOpKind.STORE || op == ContractOpKind.STOREB ||
        op == ContractOpKind.VIEW_WRITE || op == ContractOpKind.GLOBAL_WRITE ||
        op == ContractOpKind.CASC_WRITE || op == ContractOpKind.ACASC_WRITE;
}

fn void contract_require_operation(ContractProcedure* procedure) {
    if (procedure.op == ContractOpKind.NONE) return;
    ContractAccess needed = contract_op_writes(procedure.op) ?
        ContractAccess.RW : ContractAccess.RO;
    procedure.access[procedure.med] = needed;
}

fn void contract_require_call(ContractWorld* world, int proc) {
    int callee = world.procs[proc].call;
    if (callee < 0) return;
    for (int med = 0; med < CONTRACT_MED_COUNT; med++) {
        ContractAccess needed = world.procs[callee].access[med];
        ContractAccess* actual = &world.procs[proc].access[med];
        if (needed == ContractAccess.RW || *actual == ContractAccess.UNLISTED) {
            *actual = needed;
        }
    }
}

fn ContractWorld contract_valid_world(ulong seed) {
    ContractWorld world = contract_empty_world(seed);
    for (int proc = 0; proc < CONTRACT_PROC_COUNT; proc++) {
        ContractProcedure* procedure = &world.procs[proc];
        procedure.op = (ContractOpKind)((seed + (ulong)(proc * 5)) % CONTRACT_OP_COUNT);
        procedure.med = (int)((seed + (ulong)proc) % 2);
        if (procedure.op == ContractOpKind.GLOBAL_READ ||
                procedure.op == ContractOpKind.GLOBAL_WRITE) {
            procedure.med = 2;
        }
        if (proc > 0 && (seed + (ulong)proc) % 4 != 0) procedure.call = proc - 1;
        contract_require_operation(procedure);
        contract_require_call(&world, proc);
    }
    return world;
}

fn void contract_make_unlisted(ContractWorld* world, ulong seed) {
    int proc = (int)(seed % CONTRACT_PROC_COUNT);
    ContractProcedure* procedure = &world.procs[proc];
    if (procedure.op == ContractOpKind.NONE) {
        procedure.op = ContractOpKind.PROBE;
        procedure.med = 0;
    }
    procedure.call = -1;
    procedure.access[procedure.med] = ContractAccess.UNLISTED;
}

fn void contract_make_readonly(ContractWorld* world, ulong seed) {
    int proc = (int)(seed % CONTRACT_PROC_COUNT);
    for (int offset = 0; offset < CONTRACT_PROC_COUNT; offset++) {
        int candidate = (proc + offset) % CONTRACT_PROC_COUNT;
        if (contract_op_writes(world.procs[candidate].op)) {
            proc = candidate;
            break;
        }
    }
    ContractProcedure* procedure = &world.procs[proc];
    if (!contract_op_writes(procedure.op)) {
        procedure.op = ContractOpKind.STORE;
        procedure.med = 0;
    }
    procedure.call = -1;
    procedure.access[procedure.med] = ContractAccess.RO;
}

fn void contract_make_call_error(ContractWorld* world, int proc, bool outer) {
    ContractProcedure* caller = &world.procs[proc];
    int med = (caller.med + 1) % CONTRACT_MED_COUNT;
    caller.call = proc - 1;
    caller.access[med] = ContractAccess.RO;
    world.procs[proc - 1].access[med] = ContractAccess.RW;
    if (!outer) world.procs[2].call = -1;
}

fn ContractWorld contract_invalid_world(ulong seed) {
    ContractWorld world = contract_valid_world(seed);
    switch (seed % 4) {
        case 0: contract_make_unlisted(&world, seed);
        case 1: contract_make_readonly(&world, seed);
        case 2: contract_make_call_error(&world, 1, false);
        default: contract_make_call_error(&world, 2, true);
    }
    return world;
}

fn void contract_emit_memory(DString* source, ContractProcedure* procedure, int proc) {
    String med = contract_med_name(procedure.med);
    switch (procedure.op) {
        case ContractOpKind.LOAD:
            source.appendf("    load %%r1, [%s + 0]\n", med);
        case ContractOpKind.LOADB:
            source.appendf("    loadb %%r1, [%s + 0]\n", med);
        case ContractOpKind.STORE:
            source.appendf("    mov %%r0, 42\n    store [%s + 0], %%r0\n", med);
        case ContractOpKind.STOREB:
            source.appendf("    mov %%r0, 42\n    storeb [%s + 0], %%r0\n", med);
        case ContractOpKind.PROBE:
            source.appendf("    probe %s\n", med);
        case ContractOpKind.VIEW_READ:
            source.appendf("    view p%d_m, %s, 0, 8\n", proc, med);
            source.appendf("    load %%r1, [p%d_m + 0]\n", proc);
        case ContractOpKind.VIEW_WRITE:
            source.appendf("    view p%d_m, %s, 0, 8\n", proc, med);
            source.appendf("    mov %%r0, 42\n    store [p%d_m + 0], %%r0\n", proc);
        default: unreachable();
    }
}

fn void contract_emit_cascade(DString* source, ContractProcedure* procedure, int proc) {
    String med = contract_med_name(procedure.med);
    bool async = procedure.op == ContractOpKind.ACASC_READ ||
        procedure.op == ContractOpKind.ACASC_WRITE;
    if (async) {
        source.appendf("    acasc c%d: %s -> out\n", proc, med);
    } else {
        source.appendf("    casc c%d: %s -> out[p%d]\n", proc, med, proc);
    }
    if (contract_op_writes(procedure.op)) {
        source.appendf("        mov %%r0, 42\n        store [%s + 0], %%r0\n", med);
    } else {
        source.appendf("        load %%r1, [%s + 0]\n", med);
    }
    source.append("    endc\n");
}

fn void contract_emit_operation(DString* source, ContractProcedure* procedure, int proc) {
    switch (procedure.op) {
        case ContractOpKind.NONE: break;
        case ContractOpKind.GLOBAL_READ:
            source.append("    load %r1, [global_m + 0]\n");
        case ContractOpKind.GLOBAL_WRITE:
            source.append("    mov %r0, 42\n    store [global_m + 0], %r0\n");
        case ContractOpKind.CASC_READ: case ContractOpKind.CASC_WRITE:
        case ContractOpKind.ACASC_READ: case ContractOpKind.ACASC_WRITE:
            contract_emit_cascade(source, procedure, proc);
        default: contract_emit_memory(source, procedure, proc);
    }
}

fn void contract_emit_proc(DString* source, ContractProcedure* procedure, int proc) {
    source.appendf("proc p%d(", proc);
    bool first = true;
    for (int med = 0; med < CONTRACT_MED_COUNT; med++) {
        ContractAccess access = procedure.access[med];
        if (access == ContractAccess.UNLISTED) continue;
        source.appendf("%s%s: %s", first ? "" : ", ", contract_med_name(med),
            access == ContractAccess.RW ? "rw" : "ro");
        first = false;
    }
    source.append("):\n");
    contract_emit_operation(source, procedure, proc);
    if (procedure.call >= 0) source.appendf("    call p%d\n", procedure.call);
    source.append("    ret\n");
}

fn String contract_source(ContractWorld* world) {
    DString source = dstring::temp("res input, field, 8\nres result, field, 8\n"
        "med input_m, input, field\nmed result_m, result, field\n"
        "view global_m, input_m, 0, 8\n");
    for (int proc = 0; proc < CONTRACT_PROC_COUNT; proc++) {
        contract_emit_proc(&source, &world.procs[proc], proc);
    }
    source.append("mov %r0, 42\nstore [input_m + 0], %r0\n"
        "store [result_m + 0], %r0\ncall p2\n"
        "load %r1, [result_m + 0]\nprint %r1\nret\n");
    return source.str_view();
}

fn String contract_expected_output(ContractWorld* world) {
    DString output = dstring::temp();
    int proc = 2;
    while (proc >= 0) {
        if (world.procs[proc].op == ContractOpKind.PROBE) output.append("ALIVE\n");
        proc = world.procs[proc].call;
    }
    output.append("42");
    return output.str_view();
}

fn bool contract_report_mismatch(bool report, ProcessResult result, String message) {
    if (!report) return false;
    io::eprintfn("contract mismatch: %s", message);
    print_result(result);
    return false;
}

fn int contract_error_count(String text) {
    int count = 0;
    String rest = text;
    while (true) {
        sz? found = rest.index_of("VIOLATION line ");
        if (catch found) break;
        count++;
        rest = rest[found + 1..];
    }
    return count;
}

fn int contract_expected_errors(ContractExpectation expected) {
    if (expected.unlisted && (expected.op == "view" || expected.op == "cascade")) {
        return 2;
    }
    return 1;
}

fn bool? contract_invalid_matches(String path, String generated,
        ContractExpectation expected, bool report) {
    ProcessResult result = run_simple({
        compiler_path(), path, "--emit-c", "-o", generated,
    })!;
    if (result.status != 1 || result.stdout_text.len != 0 ||
            contract_error_count(result.stderr_text) != contract_expected_errors(expected) ||
            !result.stderr_text.contains(contract_diagnostic(expected))) {
        return contract_report_mismatch(report, result, "invalid contract");
    }
    Path output = path::tnew(generated)!;
    if (path::exists(output)) {
        return contract_report_mismatch(report, result, "invalid program emitted C");
    }
    return true;
}

fn bool? contract_valid_matches(String path, String generated, String executable,
        ContractWorld* world, bool report) {
    ProcessResult emitted = run_simple({compiler_path(), path, "--emit-c", "-o", generated})!;
    if (emitted.status != 0 || emitted.stdout_text.len != 0 ||
            emitted.stderr_text.len != 0) {
        return contract_report_mismatch(report, emitted, "valid contract emission");
    }
    ProcessResult compiled = compile_c(generated, executable)!;
    if (compiled.status != 0 || compiled.stderr_text.len != 0) {
        return contract_report_mismatch(report, compiled, "valid contract C compilation");
    }
    ProcessResult runtime = run_simple({executable})!;
    String expected = contract_expected_output(world);
    if (runtime.status != 0 || normalize_lines(runtime.stdout_text) != expected ||
            runtime.stderr_text.len != 0) {
        return contract_report_mismatch(report, runtime, "valid contract runtime");
    }
    return true;
}

fn int? contract_run_world(ContractWorld world, String name, bool report) {
    String path = temp_path(name);
    write_file(path, contract_source(&world))!;
    String generated = string::tformat("%s.c", path);
    ContractExpectation expected = contract_reference(&world);
    bool matches;
    if (expected.valid) {
        matches = contract_valid_matches(path, generated,
            string::tformat("%s.exe", path), &world, report)!;
    } else {
        matches = contract_invalid_matches(path, generated, expected, report)!;
    }
    return matches ? 0 : 1;
}

ulong contract_shrink_attempt;

fn bool contract_world_fails(ContractWorld world) {
    assert(contract_shrink_attempt < 1000000);
    String name = string::tformat("contract-shrink-%d.rza", contract_shrink_attempt);
    contract_shrink_attempt++;
    int? result = contract_run_world(world, name, true);
    if (catch result) return true;
    return result != 0;
}

fn ContractWorld contract_shrink(ContractWorld world, ContractPredicate fails) {
    assert(fails(world));
    ContractWorld best = world;
    for (int round = 0; round < 16; round++) {
        bool changed = false;
        for (int proc = 0; proc < CONTRACT_PROC_COUNT; proc++) {
            ContractWorld candidate = best;
            candidate.procs[proc].op = ContractOpKind.NONE;
            if (fails(candidate)) {
                best = candidate;
                changed = true;
            }
            candidate = best;
            candidate.procs[proc].call = -1;
            if (fails(candidate)) {
                best = candidate;
                changed = true;
            }
            for (int med = 0; med < CONTRACT_MED_COUNT; med++) {
                candidate = best;
                candidate.procs[proc].access[med] = ContractAccess.UNLISTED;
                if (fails(candidate)) {
                    best = candidate;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
    assert(fails(best));
    assert(best.seed == world.seed);
    return best;
}

fn bool contract_shrink_synthetic(ContractWorld world) {
    return world.procs[2].call >= 0;
}

fn int contract_shrink_selftest() {
    ContractWorld world = contract_valid_world(7);
    world.procs[2].call = 1;
    ContractWorld reduced = contract_shrink(world, &contract_shrink_synthetic);
    if (!expect(reduced.procs[2].call >= 0 && reduced.seed == world.seed,
            "contract shrink preserves failure and seed")) return 1;
    for (int proc = 0; proc < CONTRACT_PROC_COUNT; proc++) {
        if (!expect(reduced.procs[proc].op == ContractOpKind.NONE,
                "contract shrink removes irrelevant operations")) return 1;
    }
    return 0;
}

fn int? contract_harness_selftest() {
    ContractWorld world = contract_empty_world(11);
    world.procs[0].op = ContractOpKind.STORE;
    world.procs[0].access[0] = ContractAccess.RW;
    ContractExpectation flipped = contract_reference(&world);
    contract_fail(&flipped, 0, 0, "store", false);
    write_file(temp_path("flipped.rza"), contract_source(&world))!;
    bool mismatch = contract_invalid_matches(temp_path("flipped.rza"),
        temp_path("flipped.c"), flipped, false)!;
    if (!expect(!mismatch, "contract harness detects a flipped expectation")) return 1;
    if (!expect(!contract_world_fails(world), "valid shrink candidate matches")) return 1;
    world.procs[0].access[0] = ContractAccess.RO;
    if (!expect(!contract_world_fails(world),
            "invalid shrink candidate ignores stale artifacts")) return 1;
    return 0;
}

fn int? contract_run_seed(ulong seed) {
    ContractWorld valid = contract_valid_world(seed);
    if (contract_run_world(valid, string::tformat("valid-%d.rza", seed), true)! == 0) {
        contract_coverage_record(&valid, contract_reference(&valid));
    } else {
        ContractWorld reduced = contract_shrink(valid, &contract_world_fails);
        io::eprintfn("valid contract seed=%d\n%s", reduced.seed, contract_source(&reduced));
        return 1;
    }
    ContractWorld invalid = contract_invalid_world(seed);
    if (contract_run_world(invalid, string::tformat("invalid-%d.rza", seed), true)! == 0) {
        contract_coverage_record(&invalid, contract_reference(&invalid));
        return 0;
    }
    ContractWorld reduced = contract_shrink(invalid, &contract_world_fails);
    io::eprintfn("invalid contract seed=%d\n%s", reduced.seed, contract_source(&reduced));
    return 1;
}

fn int? contract_fuzz_run() {
    reset_temp_dir()!;
    if (contract_model_selftest() != 0) return 1;
    if (contract_shrink_selftest() != 0) return 1;
    if (contract_harness_selftest()! != 0) return 1;
    contract_coverage_reset();
    for (ulong seed = 1; seed <= 64; seed++) {
        if (contract_run_seed(seed)! != 0) return 1;
    }
    if (!contract_coverage_ok()) return 1;
    contract_coverage_print();
    io::printn("CONTRACT_FUZZ OK (128 programs)");
    return 0;
}

fn int contract_fuzz_main() {
    defer (void)cleanup_temp_dir();
    int? status = contract_fuzz_run();
    if (catch status) {
        io::eprintn("CONTRACT_FUZZ FAILED");
        return 1;
    }
    return status;
}
