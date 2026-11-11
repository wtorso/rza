module rza_tests;

import std::core::dstring;
import std::io;

const String GOOD_TEXT = "cav m, field\ndecay m\nret\n";

fn String mediator_source(int count) {
    DString out = dstring::temp("cav main, field\nres x, main, 8\n");
    for (int i = 0; i < count; i++) out.appendf("med m%d_m, x, main\n", i);
    out.append("decay main\nret\n");
    return out.str_view();
}

fn String cascade_source(int count) {
    DString out = dstring::temp("cav main, field\n");
    for (int i = 0; i < count; i++) {
        out.appendf("res x%d, main, 8\nmed m%d_m, x%d, main\n", i, i, i);
    }
    out.append("casc c: ");
    for (int i = 0; i < count; i++) {
        if (i > 0) out.append(",");
        out.appendf("m%d_m", i);
    }
    out.append(" -> out[main]\nendc\ndecay main\nret\n");
    return out.str_view();
}

fn String node_source(String kind, int count) {
    DString out = dstring::temp();
    for (int i = 0; i < count; i++) {
        if (kind == "frames") out.appendf("cav f%d, field\n", i);
        if (kind == "cells") out.appendf("res x%d, field, 8\n", i);
        if (kind == "labels") out.appendf("l%d:\n", i);
        if (kind == "instructions") out.append("mov %r0, 1\n");
    }
    return out.str_view();
}

fn int? compile_and_run_empty(String generated, String executable) {
    ProcessResult compiled = compile_c(generated, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "budget C compilation")) {
        print_result(compiled);
        return 1;
    }
    String[] run = { executable };
    ProcessResult result = run_simple(run)!;
    if (!expect(result.status == 0 && result.stdout_text.len == 0 &&
            result.stderr_text.len == 0, "budget runtime output")) {
        print_result(result);
        return 1;
    }
    return 0;
}

fn int? check_static(String name, String source, String expected, bool execute) {
    String path = temp_path(name);
    String source_path = string::tformat("%s.rza", path);
    write_file(source_path, source)!;
    String generated = string::tformat("%s.c", path);
    String[] check = { "./rez3asm.exe", source_path };
    String[] emit = { "./rez3asm.exe", source_path, "--emit-c", "-o", generated };
    ProcessResult result = run_simple(execute ? emit : check)!;
    if (expected.len == 0) {
        bool ok = result.status == 0 && result.stdout_text.len == 0 &&
            result.stderr_text.len == 0;
        if (!expect(ok, name)) {
            print_result(result);
            return 1;
        }
        if (execute) return compile_and_run_empty(generated,
            string::tformat("%s.exe", path));
        return 0;
    }
    bool ok = result.status == 1 && result.stdout_text.len == 0 &&
        normalize_lines(result.stderr_text) == expected;
    if (!expect(ok, name)) {
        print_result(result);
        return 1;
    }
    return 0;
}

fn int? check_node_budgets() {
    String[] kinds = { "frames", "cells", "labels", "instructions" };
    int[] accepted = { 16383, 16384, 16384, 16384 };
    for (sz i = 0; i < kinds.len; i++) {
        int ok_count = accepted[i];
        if (check_static(string::tformat("%s-%d", kinds[i], ok_count),
                node_source(kinds[i], ok_count), "", false)! != 0) return 1;
        int bad_count = ok_count + 1;
        String expected = string::tformat(
            "VIOLATION line %d [STRUCT]: too many %s", bad_count, kinds[i]);
        if (check_static(string::tformat("%s-%d", kinds[i], bad_count),
                node_source(kinds[i], bad_count), expected, false)! != 0) return 1;
    }
    return 0;
}

fn String lsp_frame(String body) {
    return string::tformat("Content-Length: %d\r\n\r\n%s", body.len, body);
}

fn String initialize(String id) {
    return string::tformat(
        `{"jsonrpc":"2.0","id":%s,"method":"initialize","params":{}}`, id);
}

fn String document_message(String uri) {
    DString out = dstring::temp(
        `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{`);
    out.append(`"textDocument":{"uri":"`);
    out.append(uri);
    out.append(`","languageId":"rza","version":1,"text":`);
    out.append(`"cav m, field\ndecay m\nret\n"}}}`);
    return out.str_view();
}

fn int? check_id_boundaries() {
    DString id = dstring::temp();
    for (int i = 0; i < 256; i++) id.append("x");
    ProcessResult ok = run_simple_input({"./rez3asm.exe", "--lsp"},
        lsp_frame(initialize(string::tformat(`"%s"`, id.str_view()))))!;
    String expected = string::tformat(`"id":"%s"`, id.str_view());
    if (!expect(ok.status == 0 && ok.stdout_text.contains(expected) &&
            ok.stderr_text.len == 0, "LSP id 256")) return 1;
    id.append("x");
    ProcessResult bad = run_simple_input({"./rez3asm.exe", "--lsp"},
        lsp_frame(initialize(string::tformat(`"%s"`, id.str_view()))))!;
    if (!expect(bad.status == 0 && bad.stdout_text.contains(`"id":null`) &&
            bad.stdout_text.contains(`"code":-32600`) &&
            bad.stderr_text.len == 0, "LSP id 257")) return 1;
    return 0;
}

fn int? check_uri_boundaries() {
    DString uri = dstring::temp("file:///");
    for (sz i = uri.len(); i < 1024; i++) uri.append("u");
    ProcessResult ok = run_simple_input({"./rez3asm.exe", "--lsp"},
        lsp_frame(document_message(uri.str_view())))!;
    String expected = string::tformat(`"uri":"%s"`, uri.str_view());
    if (!expect(ok.status == 0 && ok.stdout_text.contains(expected) &&
            ok.stdout_text.contains(`"diagnostics":[]`) &&
            ok.stderr_text.len == 0, "LSP URI 1024")) {
        print_result(ok);
        return 1;
    }
    uri.append("u");
    ProcessResult bad = run_simple_input({"./rez3asm.exe", "--lsp"},
        lsp_frame(document_message(uri.str_view())))!;
    if (!expect(bad.status == 2 && bad.stdout_text.len == 0 &&
            normalize_lines(bad.stderr_text) == "[rez3-lsp] URI exceeds static budget",
            "LSP URI 1025")) return 1;
    return 0;
}

fn String sized_header(int size) {
    String body = initialize("1");
    DString out = dstring::temp();
    out.appendf("Content-Length: %d\r\nX-Pad: ", body.len);
    for (sz i = out.len(); i < (sz)size - 4; i++) out.append("x");
    out.append("\r\n\r\n");
    out.append(body);
    return out.str_view();
}

fn int? check_header_boundaries() {
    ProcessResult ok = run_simple_input({"./rez3asm.exe", "--lsp"},
        sized_header(8192))!;
    if (!expect(ok.status == 0 && ok.stdout_text.contains(`"id":1`) &&
            ok.stderr_text.len == 0, "LSP header 8192")) return 1;
    ProcessResult bad = run_simple_input({"./rez3asm.exe", "--lsp"},
        sized_header(8193))!;
    if (!expect(bad.status == 2 && bad.stdout_text.len == 0 &&
            normalize_lines(bad.stderr_text) == "[rez3-lsp] header too large",
            "LSP header 8193")) return 1;
    return 0;
}

fn int budgets_main() {
    int? status = budgets_run();
    if (catch status) {
        io::eprintn("TINY_BUDGETS FAILED");
        return 1;
    }
    return status;
}

fn int? budgets_run() {
    reset_temp_dir()!;
    if (check_static("mediators-64", mediator_source(64), "", true)! != 0) return 1;
    if (check_static("mediators-65", mediator_source(65),
            "VIOLATION line 67 [STRUCT]: too many mediators for one cell", false)! != 0) {
        return 1;
    }
    if (check_static("cascade-64", cascade_source(64), "", true)! != 0) return 1;
    if (check_static("cascade-65", cascade_source(65),
            "VIOLATION line 132 [STRUCT]: too many cascade inputs", false)! != 0) {
        return 1;
    }
    if (check_node_budgets()! != 0) return 1;
    if (check_id_boundaries()! != 0) return 1;
    if (check_uri_boundaries()! != 0) return 1;
    if (check_header_boundaries()! != 0) return 1;
    io::printn("TINY_BUDGETS OK (18 cases)");
    return 0;
}
