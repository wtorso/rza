module rza_tests;

import std::io;

const String CONTRACT_VALID = "res input, field, 8\nres result, field, 8\n"
    "med input_m, input, field\nmed result_m, result, field\n"
    "proc convert(input_m: ro, result_m: rw):\n"
    "    load %r0, [input_m + 0]\n    cinc %r0\n"
    "    store [result_m + 0], %r0\n    ret\n"
    "mov %r0, 41\nstore [input_m + 0], %r0\n"
    "call convert\nload %r1, [result_m + 0]\nprint %r1\nret\n";

const String CONTRACT_EMPTY = "proc pure():\n    ret\n"
    "call pure\nmov %r0, 42\nprint %r0\nret\n";

const String CONTRACT_PREFIX = "res input, field, 8\nres result, field, 8\n"
    "med input_m, input, field\nmed result_m, result, field\n";

fn int? contract_valid_case(String name, String source, String expected) {
    String path = temp_path(name);
    write_file(path, source)!;
    String generated = temp_path("contract.c");
    String executable = temp_path("contract.exe");
    ProcessResult emitted = run_simple({compiler_path(), path, "--emit-c", "-o", generated})!;
    if (!expect(emitted.status == 0 && emitted.stdout_text.len == 0 &&
            emitted.stderr_text.len == 0, "valid contract emission")) {
        print_result(emitted);
        return 1;
    }
    ProcessResult compiled = compile_c(generated, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "valid contract compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({executable})!;
    if (!expect(runtime.status == 0 && normalize_lines(runtime.stdout_text) == expected &&
            runtime.stderr_text.len == 0, "valid contract runtime")) {
        print_result(runtime);
        return 1;
    }
    return 0;
}

fn int? contract_invalid_case(String name, String body, String diagnostic) {
    String path = temp_path(name);
    DString source = dstring::temp(CONTRACT_PREFIX);
    source.append(body);
    write_file(path, source.str_view())!;
    ProcessResult result = run_simple({compiler_path(), path})!;
    bool valid = result.status == 1 && result.stdout_text.len == 0 &&
        result.stderr_text.contains(diagnostic);
    if (!expect(valid, name)) {
        print_result(result);
        return 1;
    }
    return 0;
}

fn int? proc_contracts_run() {
    reset_temp_dir()!;
    if (contract_valid_case("valid.rza", CONTRACT_VALID, "42")! != 0) return 1;
    if (contract_valid_case("empty.rza", CONTRACT_EMPTY, "42")! != 0) return 1;
    if (contract_invalid_case("readonly.rza",
            "proc bad(input_m: ro):\n    store [input_m + 0], %r0\n    ret\nret\n",
            "store via read-only mediator input_m")! != 0) return 1;
    if (contract_invalid_case("unlisted.rza",
            "proc bad(input_m: ro):\n    load %r0, [result_m + 0]\n    ret\nret\n",
            "load via unlisted mediator result_m")! != 0) return 1;
    if (contract_invalid_case("unknown.rza",
            "proc bad(unknown_m: ro):\n    ret\nret\n",
            "unknown contract mediator unknown_m")! != 0) return 1;
    if (contract_invalid_case("duplicate.rza",
            "proc bad(input_m: ro, input_m: rw):\n    ret\nret\n",
            "duplicate contract mediator input_m")! != 0) return 1;
    if (contract_invalid_case("capability.rza",
            "proc bad(input_m: wo):\n    ret\nret\n",
            "invalid contract capability wo")! != 0) return 1;
    if (contract_invalid_case("malformed.rza",
            "proc bad(input_m: ro:\n    ret\nret\n", "malformed proc contract")! != 0) return 1;
    if (contract_invalid_case("bypass.rza",
            "proc bad(input_m: ro):\n    med alias_m, input, field\n    ret\nret\n",
            "mediator declaration in contracted proc")! != 0) return 1;
    io::printn("PROC_CONTRACTS OK");
    return 0;
}

fn int proc_contracts_main() {
    defer (void)cleanup_temp_dir();
    int? status = proc_contracts_run();
    if (catch status) {
        io::eprintn("PROC_CONTRACTS FAILED");
        return 1;
    }
    return status;
}
