module rza_tests;

import std::core::dstring;
import std::io;

fn bool ownership_runtime_matches(ProcessResult result, OwnershipCase expected) {
    return result.status == expected.status &&
        normalize_lines(result.stdout_text) == normalize_lines(expected.stdout_text) &&
        normalize_lines(result.stderr_text) == normalize_lines(expected.stderr_text);
}

fn int? run_ownership_case(OwnershipCase expected, String name, bool inject) {
    String source = temp_path(name);
    write_file(source, expected.source)!;
    String generated = string::tformat("%s.c", source);
    String[] emit = { compiler_path(), source, "--emit-c", "-o", generated };
    String[] check = { compiler_path(), source };
    ProcessResult transpiled = run_simple(expected.static_error ? check : emit)!;
    if (expected.static_error) {
        bool ok = transpiled.status == 1 && transpiled.stdout_text.len == 0 &&
            normalize_lines(transpiled.stderr_text) == normalize_lines(expected.stderr_text);
        if (!expect(ok, name)) {
            print_result(transpiled);
            return 1;
        }
        return 0;
    }
    if (!expect(transpiled.status == 0, name)) {
        print_result(transpiled);
        return 1;
    }
    String executable = string::tformat("%s.exe", source);
    ProcessResult compiled = compile_c(generated, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "ownership C compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    if (!expect(ownership_runtime_matches(runtime, expected), name)) {
        print_result(runtime);
        return 1;
    }
    if (inject) {
        DString stderr = dstring::temp(runtime.stderr_text);
        stderr.append("unexpected diagnostic\n");
        runtime.stderr_text = stderr.str_view();
        if (!expect(!ownership_runtime_matches(runtime, expected),
                "valid case accepted unexpected stderr")) return 1;
    }
    return 0;
}

fn int? run_ownership_view_mutation(OwnershipCase expected, String name) {
    String source = temp_path(name);
    write_file(source, expected.source)!;
    String generated = string::tformat("%s.c", source);
    ProcessResult transpiled = run_simple({
        compiler_path(), source, "--emit-c", "-o", generated,
    })!;
    if (!expect(transpiled.status == 0, "view mutation emit")) {
        print_result(transpiled);
        return 1;
    }
    char[] data = read_file(generated, artifact_output_buf[..])!;
    String text = (String)data;
    String needle = "if (!rez_view_cell(";
    sz? found = text.index_of(needle);
    if (try found) {
        DString mutated = dstring::temp();
        mutated.append_string(text[:found]);
        mutated.append_string("if (g_async.count > REZ_ASYNC_MAX && !rez_view_cell(");
        mutated.append_string(text[found + needle.len..]);
        write_file(generated, mutated.str_view())!;
    }
    String executable = string::tformat("%s.exe", source);
    ProcessResult compiled = compile_c(generated, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "view mutation C compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    if (ownership_runtime_matches(runtime, expected)) return 0;
    return 1;
}

const int128 OWN_I64_MAX = 9223372036854775807;
const int128 OWN_I64_MIN = -9223372036854775807 - 1;

fn long own_random_i64(OwnRng* rng) {
    ulong raw = rng.next();
    if (raw <= (ulong)OWN_I64_MAX) return (long)raw;
    return -1 - (long)(18446744073709551615 - raw);
}

fn OwnershipCase own_checked_case(long left, long right, int operation) {
    String[] opcodes = { "cadd", "csub", "cmul" };
    DString source = dstring::temp();
    source.appendf("mov %%r0, %d\n", left);
    source.appendf("mov %%r1, %d\n", right);
    source.appendf("%s %%r2, %%r0, %%r1\nprint %%r2\nret\n", opcodes[operation]);
    int128 value;
    switch (operation) {
        case 0: value = (int128)left + (int128)right;
        case 1: value = (int128)left - (int128)right;
        default: value = (int128)left * (int128)right;
    }
    if (value > OWN_I64_MAX || value < OWN_I64_MIN) {
        return {
            .source = source.str_view(),
            .stdout_text = "",
            .stderr_text = "FAULT line 3: arithmetic overflow\n",
            .status = 1,
            .static_error = false
        };
    }
    DString expected = dstring::temp();
    expected.appendf("%d\n", (long)value);
    return {
        .source = source.str_view(),
        .stdout_text = expected.str_view(),
        .stderr_text = "",
        .status = 0,
        .static_error = false
    };
}

fn int? run_checked_edges() {
    long[] edges = {
        -9223372036854775807 - 1, -9223372036854775807, -1, 0, 1,
        9223372036854775806, 9223372036854775807, 2, -2, 10
    };
    long[] directed_left = {
        -9223372036854775807 - 1, 0, 9223372036854775807,
        -9223372036854775807 - 1, -9223372036854775807 - 1,
        9223372036854775807, 9223372036854775807, -9223372036854775807 - 1
    };
    long[] directed_right = { -1, -9223372036854775807 - 1, 1, 1, 0, 1, -1,
        -9223372036854775807 - 1 };
    int[] directed_operations = { 2, 1, 0, 1, 2, 2, 2, 0 };
    int directed_count = (int)directed_left.len;
    OwnRng rng = { 0xC0DEC };
    int successes = 0;
    int faults = 0;
    bool min_times_minus_one = false;
    bool zero_minus_min = false;
    for (int i = 0; i < 32 + directed_count; i++) {
        long left;
        long right;
        int operation;
        if (i < 32) {
            left = i < (int)edges.len ? edges[i] : own_random_i64(&rng);
            right = i < (int)edges.len ? edges[(i * 3 + 1) % (int)edges.len]
                : own_random_i64(&rng);
            operation = i % 3;
        } else {
            int directed = i - 32;
            left = directed_left[directed];
            right = directed_right[directed];
            operation = directed_operations[directed];
        }
        if (left == (long)OWN_I64_MIN && right == -1 && operation == 2) {
            min_times_minus_one = true;
        }
        if (left == 0 && right == (long)OWN_I64_MIN && operation == 1) {
            zero_minus_min = true;
        }
        OwnershipCase expected = own_checked_case(left, right, operation);
        if (expected.status == 0) {
            successes++;
        } else {
            faults++;
        }
        String name = string::tformat("checked-edge-%d.rza", i);
        if (run_ownership_case(expected, name, false)! != 0) return 1;
    }
    if (!expect(successes > 0 && faults > 0 && min_times_minus_one && zero_minus_min,
            "checked directed edge coverage")) return 1;
    return 0;
}

fn int ownership_main() {
    defer (void)cleanup_temp_dir();
    int? status = ownership_run();
    if (catch status) {
        io::eprintn("OWNERSHIP_FUZZ FAILED");
        return 1;
    }
    return status;
}

fn int? ownership_run() {
    reset_temp_dir()!;
    for (int seed = 1; seed <= 64; seed++) {
        if (run_ownership_case(own_valid(seed), string::tformat("valid-%d.rza", seed),
                seed == 1)! != 0) return 1;
    }
    String[] rules = { "I1", "I2", "I3", "I4", "DECAY", "DUP", "STRUCT",
        "SCOPE", "FAULT", "ABORT" };
    for (sz i = 0; i < rules.len; i++) {
        String name = string::tformat("invalid-%s.rza", rules[i]);
        if (run_ownership_case(own_invalid(rules[i]), name, false)! != 0) return 1;
    }
    if (run_checked_edges()! != 0) return 1;
    io::printn("OWNERSHIP_FUZZ OK (114 cases)");
    return 0;
}
