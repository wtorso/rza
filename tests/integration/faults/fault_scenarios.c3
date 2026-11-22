module rza_tests;

import libc;
import std::collections::object;
import std::core::dstring;
import std::io;
import std::io::file;
import std::io::path;
import std::os::process;

fn String? read_child_stderr(Process* child) {
    return lsp_stderr_text();
}

fn int? test_lsp_boundaries() {
    Process child = lsp_start()!;
    defer lsp_destroy(&child);
    String first = lsp_frame(initialize("1"));
    for (sz i = 0; i < first.len; i++) lsp_send(&child, first[i:1])!;
    if (!expect(json_id_int(json_message(lsp_recv(&child)!)!, 1),
            "split initialize")) return 1;
    DString pair = dstring::temp(lsp_frame(initialize("2")));
    pair.append(lsp_frame(initialize("3")));
    lsp_send(&child, pair.str_view())!;
    if (!expect(json_id_int(json_message(lsp_recv(&child)!)!, 2),
            "pipeline first")) return 1;
    if (!expect(json_id_int(json_message(lsp_recv(&child)!)!, 3),
            "pipeline second")) return 1;
    String body = initialize("4");
    String duplicate = string::tformat(
        "Content-Length: %d\r\nContent-Length: %d\r\n\r\n%s",
        body.len, body.len, body);
    lsp_send(&child, duplicate)!;
    if (!expect(json_id_int(json_message(lsp_recv(&child)!)!, 4),
            "duplicate length")) return 1;
    lsp_send(&child, "Content-Length: 1\r\n\r\n{")!;
    lsp_send(&child, lsp_frame(initialize("5")))!;
    if (!expect(json_id_int(json_message(lsp_recv(&child)!)!, 5),
            "JSON recovery")) return 1;
    String unknown = `{"jsonrpc":"2.0","id":6,"method":"unknown/method"}`;
    lsp_send(&child, lsp_frame(unknown))!;
    if (!expect(json_error_code(json_message(lsp_recv(&child)!)!, -32601),
            "unknown method")) return 1;
    String boolean = `{"jsonrpc":"2.0","id":true,"method":"initialize"}`;
    lsp_send(&child, lsp_frame(boolean))!;
    Object* boolean_response = json_message(lsp_recv(&child)!)!;
    if (!expect(json_id_null(boolean_response) &&
            json_error_code(boolean_response, -32600), "boolean id")) return 1;
    child.terminate()!;
    (void)wait_process(&child);
    String stderr = read_child_stderr(&child)!;
    if (!expect(normalize_lines(stderr) == "[rez3-lsp] bad JSON-RPC payload",
            "malformed JSON diagnostic")) return 1;
    return 0;
}

fn int? test_conflicting_length() {
    String body = initialize("1");
    String payload = string::tformat(
        "Content-Length: 0\r\nContent-Length: %d\r\n\r\n%s", body.len, body);
    ProcessResult result = run_simple_input({compiler_path(), "--lsp"}, payload)!;
    if (!expect(result.status == 2 && result.stdout_text.len == 0 &&
            normalize_lines(result.stderr_text) == "[rez3-lsp] conflicting Content-Length",
            "conflicting Content-Length")) return 1;
    return 0;
}

fn int? test_exit_codes() {
    String exit_frame = lsp_frame(`{"jsonrpc":"2.0","method":"exit"}`);
    ProcessResult early = run_simple_input({compiler_path(), "--lsp"}, exit_frame)!;
    if (!expect(early.status == 1, "exit before shutdown")) return 1;
    DString normal = dstring::temp(lsp_frame(
        `{"jsonrpc":"2.0","id":1,"method":"shutdown"}`));
    normal.append(exit_frame);
    ProcessResult done = run_simple_input({compiler_path(), "--lsp"},
        normal.str_view())!;
    Object* response = json_framed(done.stdout_text)!;
    Object* result = response.get("result")!;
    if (!expect(done.status == 0 && json_id_int(response, 1) && result.is_null() &&
            !response.has_key("error"), "shutdown and exit")) return 1;
    ProcessResult eof = run_simple_input({compiler_path(), "--lsp"}, "")!;
    if (!expect(eof.status == 0, "LSP EOF")) return 1;
    return 0;
}

fn int? test_cli_failures() {
    ProcessResult missing = run_simple({compiler_path(), "does-not-exist.rza"})!;
    if (!expect(missing.status == 2, "missing input")) return 1;
    String directory = temp_path("output-directory");
    path::mkdir(path::tnew(directory)!, true)!;
    ProcessResult output = run_simple({compiler_path(), "tests/fixtures/core/fib.rza",
        "--emit-c", "-o", directory})!;
    if (!expect(output.status == 2, "output is directory")) return 1;
    return 0;
}

fn int? test_io_failure(bool stdout_failure) {
    String path = temp_path(stdout_failure ? "read-only-output" : "write-only-input");
    write_file(path, "")!;
    File special = file::open(path, stdout_failure ? "rb" : "wb")!;
    defer (void)special.close();
    CFile raw = libc::tmpfile();
    if (raw == null) return TEST_ERROR~;
    lsp_stderr_file = file::from_handle(raw);
    Process child = process::spawn({compiler_path(), "--lsp"},
        SpawnOptions.INHERIT_ENV, {},
        stdout_failure ? process::CAPTURE : process_file(special),
        stdout_failure ? process_file(special) : process::CAPTURE,
        process_file(lsp_stderr_file))!;
    defer lsp_destroy(&child);
    if (stdout_failure) lsp_send(&child, lsp_frame(initialize("1")))!;
    int status = wait_process(&child)!;
    String expected = stdout_failure ? "[rez3-lsp] stdout write failed" :
        "[rez3-lsp] stdin read failed";
    String stderr = read_child_stderr(&child)!;
    bool stdout_empty = true;
    if (!stdout_failure) {
        char[1] buffer;
        stdout_empty = child.read_stdout(buffer[..].ptr, 1)! == 0;
    }
    if (!expect(status == 2 && stdout_empty && normalize_lines(stderr) == expected,
            "LSP descriptor failure")) return 1;
    return 0;
}

fn int? test_abi_faults() {
    String executable = temp_path("abi_faults.exe");
    ProcessResult compiled = compile_c("tests/host/abi_faults.c", executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "ABI fault compilation")) return 1;
    ProcessResult runtime = run_program({ executable })!;
    if (!expect(runtime.status == 0 && runtime.stderr_text.len == 0,
            "ABI fault runtime")) return 1;
    return 0;
}

fn int? fault_scenarios_run() {
    reset_temp_dir()!;
    if (test_lsp_boundaries()! != 0) return 1;
    if (test_conflicting_length()! != 0) return 1;
    if (test_exit_codes()! != 0) return 1;
    if (test_cli_failures()! != 0) return 1;
    if (test_io_failure(false)! != 0) return 1;
    if (test_io_failure(true)! != 0) return 1;
    if (test_abi_faults()! != 0) return 1;
    return 0;
}
