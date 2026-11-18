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

fn int? contract_valid_body_expected(String name, String body, String expected) {
    DString source = dstring::temp(CONTRACT_PREFIX);
    source.append(body);
    return contract_valid_case(name, source.str_view(), expected);
}

fn int? contract_valid_body(String name, String body) {
    return contract_valid_body_expected(name, body, "42");
}

fn int? contract_capacity_case() {
    const int CONTRACT_LIMIT = 64;
    DString body = dstring::temp();
    for (int i = 0; i <= CONTRACT_LIMIT; i++) {
        String cell = i % 2 == 0 ? "input" : "result";
        body.appendf("med c%d_m, %s, field\n", i, cell);
    }
    body.append("proc bad(");
    for (int i = 0; i <= CONTRACT_LIMIT; i++) {
        body.appendf("%sc%d_m: ro", i == 0 ? "" : ", ", i);
    }
    body.append("):\n    ret\nret\n");
    return contract_invalid_case("capacity.rza", body.str_view(),
        "proc contract capacity exceeded");
}

fn int? proc_contracts_direct() {
    if (contract_invalid_case("trailing-comma.rza",
            "proc bad(input_m: ro,):\n    ret\nret\n",
            "malformed proc contract entry")! != 0) return 1;
    if (contract_invalid_case("leading-comma.rza",
            "proc bad(, input_m: ro):\n    ret\nret\n",
            "malformed proc contract entry")! != 0) return 1;
    if (contract_invalid_case("double-comma.rza",
            "proc bad(input_m: ro,, result_m: rw):\n    ret\nret\n",
            "malformed proc contract entry")! != 0) return 1;
    if (contract_invalid_case("extra-close.rza",
            "proc bad(input_m: ro)):\n    ret\nret\n",
            "invalid contract capability ro)")! != 0) return 1;
    if (contract_invalid_case("extra-open.rza",
            "proc bad((input_m: ro):\n    ret\nret\n", "[STRUCT]")! != 0) return 1;
    if (contract_capacity_case()! != 0) return 1;
    if (contract_invalid_case("readonly.rza",
            "proc bad(input_m: ro):\n    store [input_m + 0], %r0\n    ret\nret\n",
            "proc bad: store via read-only mediator input_m")! != 0) return 1;
    if (contract_invalid_case("readonly-byte.rza",
            "proc bad(input_m: ro):\n    storeb [input_m + 0], %r0\n    ret\nret\n",
            "proc bad: storeb via read-only mediator input_m")! != 0) return 1;
    if (contract_invalid_case("unlisted.rza",
            "proc bad(input_m: ro):\n    load %r0, [result_m + 0]\n    ret\nret\n",
            "proc bad: load via unlisted mediator result_m")! != 0) return 1;
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
    return 0;
}

fn int? proc_contracts_direct_valid() {
    if (contract_valid_body_expected("direct-read.rza",
            "proc read_all(input_m: ro):\n"
            "    load %r0, [input_m + 0]\n    loadb %r1, [input_m + 0]\n"
            "    probe input_m\n    ret\n"
            "mov %r0, 42\nstore [input_m + 0], %r0\n"
            "call read_all\nload %r1, [input_m + 0]\nprint %r1\nret\n",
            "ALIVE\n42")! != 0) return 1;
    if (contract_valid_body_expected("direct-write.rza",
            "proc write_all(result_m: rw):\n    mov %r0, 42\n"
            "    store [result_m + 0], %r0\n    storeb [result_m + 0], %r0\n"
            "    probe result_m\n    ret\n"
            "call write_all\nload %r1, [result_m + 0]\nprint %r1\nret\n",
            "ALIVE\n42")! != 0) return 1;
    if (contract_valid_body("legacy.rza",
            "proc legacy:\n    load %r0, [input_m + 0]\n"
            "    store [result_m + 0], %r0\n    ret\n"
            "mov %r0, 42\nstore [input_m + 0], %r0\n"
            "call legacy\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    return 0;
}

fn int? proc_contracts_views_valid() {
    if (contract_valid_body("view-write.rza",
            "proc write_view(input_m: rw):\n"
            "    view part_m, input_m, 0, 8\n    mov %r0, 42\n"
            "    store [part_m + 0], %r0\n    ret\n"
            "call write_view\nload %r1, [input_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_valid_body("view-read.rza",
            "proc read_view(input_m: ro, result_m: rw):\n    view part_m, input_m, 0, 8\n"
            "    load %r0, [part_m + 0]\n    store [result_m + 0], %r0\n    ret\n"
            "mov %r0, 42\nstore [input_m + 0], %r0\n"
            "call read_view\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_valid_body("global-view-read.rza",
            "view global_m, input_m, 0, 8\nproc read_global(global_m: ro, result_m: rw):\n"
            "    load %r0, [global_m + 0]\n    store [result_m + 0], %r0\n    ret\n"
            "mov %r0, 42\nstore [input_m + 0], %r0\n"
            "call read_global\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    return 0;
}

fn int? proc_contracts_views_invalid() {
    if (contract_invalid_case("view-readonly.rza",
            "proc bad(input_m: ro):\n    view part_m, input_m, 0, 1\n"
            "    storeb [part_m + 0], %r0\n    ret\nret\n",
            "proc bad: storeb via read-only mediator part_m")! != 0) return 1;
    if (contract_invalid_case("global-view.rza",
            "view global_m, input_m, 0, 1\nproc bad(input_m: ro):\n"
            "    storeb [global_m + 0], %r0\n    ret\nret\n",
            "proc bad: storeb via unlisted mediator global_m")! != 0) return 1;
    if (contract_invalid_case("global-view-read-unlisted.rza",
            "view global_m, input_m, 0, 8\nproc bad(input_m: rw):\n"
            "    load %r0, [global_m + 0]\n    ret\nret\n",
            "proc bad: load via unlisted mediator global_m")! != 0) return 1;
    if (contract_invalid_case("global-view-readonly.rza",
            "view global_m, input_m, 0, 8\nproc bad(global_m: ro, input_m: rw):\n"
            "    store [global_m + 0], %r0\n    ret\nret\n",
            "proc bad: store via read-only mediator global_m")! != 0) return 1;
    if (contract_invalid_case("probe-unlisted.rza",
            "proc bad(input_m: ro):\n    probe result_m\n    ret\nret\n",
            "proc bad: probe via unlisted mediator result_m")! != 0) return 1;
    if (contract_invalid_case("view-unlisted.rza",
            "proc bad(input_m: ro):\n    view part_m, result_m, 0, 1\n    ret\nret\n",
            "proc bad: view via unlisted mediator result_m")! != 0) return 1;
    return 0;
}

fn int? proc_contracts_cascades() {
    if (contract_valid_body("cascade-valid.rza",
            "proc sync(input_m: ro, result_m: rw):\n"
            "    casc work: input_m,result_m -> out[sync]\n"
            "        load %r0, [input_m + 0]\n    store [result_m + 0], %r0\n"
            "    endc\n    ret\nmov %r0, 42\nstore [input_m + 0], %r0\n"
            "call sync\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_valid_body("async-valid.rza",
            "proc async(input_m: ro, result_m: rw):\n"
            "    acasc work: input_m,result_m -> out\n"
            "        load %r0, [input_m + 0]\n    store [result_m + 0], %r0\n"
            "    endc\n    ret\nmov %r0, 42\nstore [input_m + 0], %r0\n"
            "call async\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_invalid_case("cascade-unlisted.rza",
            "proc bad(input_m: ro):\n    casc work: result_m -> output[field]\n"
            "    endc\n    ret\nret\n",
            "cascade via unlisted mediator result_m")! != 0) return 1;
    if (contract_invalid_case("cascade-readonly.rza",
            "proc bad(input_m: ro):\n    casc work: input_m -> output[field]\n"
            "    store [input_m + 0], %r0\n    endc\n    ret\nret\n",
            "proc bad: store via read-only mediator input_m")! != 0) return 1;
    if (contract_invalid_case("async-readonly.rza",
            "proc bad(input_m: ro):\n    acasc work: input_m -> output\n"
            "    store [input_m + 0], %r0\n    endc\n    ret\nret\n",
            "proc bad: store via read-only mediator input_m")! != 0) return 1;
    return 0;
}

fn int? proc_contracts_calls() {
    if (contract_valid_body("call-readonly.rza",
            "proc callee(input_m: ro):\n    load %r0, [input_m + 0]\n    ret\n"
            "proc caller(input_m: rw):\n    call callee\n    ret\n"
            "call caller\nmov %r0, 42\nprint %r0\nret\n")! != 0) return 1;
    if (contract_valid_body("legacy-caller.rza",
            "proc callee(input_m: ro):\n    load %r0, [input_m + 0]\n    ret\n"
            "proc legacy:\n    call callee\n    ret\n"
            "mov %r0, 42\nstore [input_m + 0], %r0\ncall legacy\n"
            "load %r1, [input_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_invalid_case("call-escalation.rza",
            "proc callee(result_m: rw):\n    store [result_m + 0], %r0\n    ret\n"
            "proc caller(result_m: ro):\n    call callee\n    ret\nret\n",
            "proc caller: call requires rw access to result_m (callee callee)")! != 0) return 1;
    if (contract_invalid_case("call-unlisted.rza",
            "proc callee(input_m: ro):\n    load %r0, [input_m + 0]\n    ret\n"
            "proc caller():\n    call callee\n    ret\nret\n",
            "proc caller: call uses unlisted mediator input_m (callee callee)")! != 0) return 1;
    if (contract_invalid_case("call-legacy.rza",
            "proc legacy:\n    ret\nproc caller():\n    call legacy\n    ret\nret\n",
            "proc caller: call to uncontracted proc legacy")! != 0) return 1;
    return 0;
}

fn int? proc_contracts_transitive() {
    if (contract_valid_body("call-chain.rza",
            "proc leaf(result_m: rw):\n    mov %r0, 42\n"
            "    store [result_m + 0], %r0\n    ret\n"
            "proc middle(result_m: rw):\n    call leaf\n    ret\n"
            "proc caller(result_m: rw):\n    call middle\n    ret\n"
            "call caller\nload %r1, [result_m + 0]\nprint %r1\nret\n")! != 0) return 1;
    if (contract_invalid_case("call-chain-deep.rza",
            "proc leaf(result_m: rw):\n    store [result_m + 0], %r0\n    ret\n"
            "proc middle(result_m: ro):\n    call leaf\n    ret\n"
            "proc caller(result_m: ro):\n    call middle\n    ret\nret\n",
            "proc middle: call requires rw access to result_m (callee leaf)")! != 0) return 1;
    if (contract_invalid_case("call-chain-outer.rza",
            "proc leaf(input_m: ro):\n    load %r0, [input_m + 0]\n    ret\n"
            "proc middle(input_m: rw):\n    call leaf\n    ret\n"
            "proc caller(input_m: ro):\n    call middle\n    ret\nret\n",
            "proc caller: call requires rw access to input_m (callee middle)")! != 0) return 1;
    if (contract_invalid_case("call-chain-unlisted.rza",
            "proc leaf(input_m: ro):\n    load %r0, [input_m + 0]\n    ret\n"
            "proc middle():\n    call leaf\n    ret\n"
            "proc caller(input_m: ro):\n    call middle\n    ret\nret\n",
            "proc middle: call uses unlisted mediator input_m (callee leaf)")! != 0) return 1;
    return 0;
}

fn int? contract_emit(String source, String path, String generated) {
    write_file(path, source)!;
    ProcessResult result = run_simple({compiler_path(), path, "--emit-c", "-o", generated})!;
    if (!expect(result.status == 0 && result.stderr_text.len == 0, "erasure emission")) {
        print_result(result);
        return 1;
    }
    return 0;
}

fn String? contract_c_without_hash(char[] data) {
    String marker = "/* Source-SHA256: ";
    sz? found = ((String)data).index_of(marker);
    if (catch found) return TEST_ERROR~;
    sz start = found + marker.len;
    if (start + 64 > data.len) return TEST_ERROR~;
    for (sz i = 0; i < 64; i++) data[start + i] = 'x';
    return (String)data;
}

char[1048576] contract_legacy_c;
char[1048576] contract_modern_c;

fn int? contract_erasure_case() {
    DString legacy = dstring::temp(CONTRACT_PREFIX);
    legacy.append("proc convert:\n    load %r0, [input_m + 0]\n    cinc %r0\n"
        "    store [result_m + 0], %r0\n    ret\nmov %r0, 41\n"
        "store [input_m + 0], %r0\ncall convert\nload %r1, [result_m + 0]\n"
        "print %r1\nret\n");
    DString modern = dstring::temp(CONTRACT_PREFIX);
    modern.append("proc convert(input_m: ro, result_m: rw):\n"
        "    load %r0, [input_m + 0]\n    cinc %r0\n"
        "    store [result_m + 0], %r0\n    ret\nmov %r0, 41\n"
        "store [input_m + 0], %r0\ncall convert\nload %r1, [result_m + 0]\n"
        "print %r1\nret\n");
    String path = temp_path("erasure.rza");
    String generated = temp_path("erasure.c");
    if (contract_emit(legacy.str_view(), path, generated)! != 0) return 1;
    char[] old_c = read_file(generated, contract_legacy_c[..])!;
    if (contract_emit(modern.str_view(), path, generated)! != 0) return 1;
    char[] new_c = read_file(generated, contract_modern_c[..])!;
    String old_text = contract_c_without_hash(old_c)!;
    String new_text = contract_c_without_hash(new_c)!;
    if (!expect(old_text == new_text, "contracts must erase before C generation")) return 1;
    if (contract_valid_case("erasure-legacy.rza", legacy.str_view(), "42")! != 0) return 1;
    return contract_valid_case("erasure-modern.rza", modern.str_view(), "42");
}

fn int? proc_contracts_run() {
    reset_temp_dir()!;
    if (contract_valid_case("valid.rza", CONTRACT_VALID, "42")! != 0) return 1;
    if (contract_valid_case("empty.rza", CONTRACT_EMPTY, "42")! != 0) return 1;
    if (proc_contracts_direct()! != 0) return 1;
    if (proc_contracts_direct_valid()! != 0) return 1;
    if (proc_contracts_views_valid()! != 0) return 1;
    if (proc_contracts_views_invalid()! != 0) return 1;
    if (proc_contracts_cascades()! != 0) return 1;
    if (proc_contracts_calls()! != 0) return 1;
    if (proc_contracts_transitive()! != 0) return 1;
    if (contract_erasure_case()! != 0) return 1;
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
