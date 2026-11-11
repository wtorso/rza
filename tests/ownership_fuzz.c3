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
    String[] emit = { "./rez3asm.exe", source, "--emit-c", "-o", generated };
    String[] check = { "./rez3asm.exe", source };
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
    for (int seed = 1; seed <= 12; seed++) {
        if (run_ownership_case(own_valid(seed), string::tformat("valid-%d.rza", seed),
                seed == 1)! != 0) return 1;
    }
    String[] rules = { "I1", "I2", "I3", "I4", "DECAY", "DUP", "STRUCT",
        "SCOPE", "FAULT", "ABORT" };
    for (sz i = 0; i < rules.len; i++) {
        String name = string::tformat("invalid-%s.rza", rules[i]);
        if (run_ownership_case(own_invalid(rules[i]), name, false)! != 0) return 1;
    }
    io::printn("OWNERSHIP_FUZZ OK (22 cases)");
    return 0;
}
