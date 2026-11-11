module rza_tests;

import std::core::dstring;
import std::io;
import std::io::path;
import std::os::process;
import std::thread;

const String BAD_URI = "file:///smoke-bad.rza";
const String GOOD_URI = "file:///smoke-good.rza";
const String BAD_TEXT = "cav a\n";
const String GOOD_TEXT = "cav m, field\ndecay m\nret\n";
const String CASCADE_TEXT = "cav m, field\nres x, m, 8\nmed x_m, x, m\n"
    "casc c: x_m -> out[m]\n load %r0, [x_m + 0]\nendc\ndecay m\nret\n";
const ulong MEMORY_GROWTH_MAX = 512 * 1024;

fn void json_string(DString* out, String text) {
    out.append_char('"');
    for (sz i = 0; i < text.len; i++) {
        char c = text[i];
        if (c == '"') { out.append(`\"`); }
        else if (c == '\\') { out.append(`\\`); }
        else if (c == '\n') { out.append(`\n`); }
        else if (c == '\r') { out.append(`\r`); }
        else if (c == '\t') { out.append(`\t`); }
        else { out.append_char(c); }
    }
    out.append_char('"');
}

fn String open_message(String uri, String text, int version) {
    DString out = dstring::temp(`{"jsonrpc":"2.0","method":"textDocument/didOpen",`);
    out.append(`"params":{"textDocument":{"uri":`);
    json_string(&out, uri);
    out.append(`,"languageId":"rza","version":`);
    out.appendf("%d", version);
    out.append(`,"text":`);
    json_string(&out, text);
    out.append(`}}}`);
    return out.str_view();
}

fn String change_message(String text, int version) {
    DString out = dstring::temp(`{"jsonrpc":"2.0","method":"textDocument/didChange",`);
    out.append(`"params":{"textDocument":{"uri":"file:///smoke-good.rza","version":`);
    out.appendf("%d", version);
    out.append(`},"contentChanges":[{"text":`);
    json_string(&out, text);
    out.append(`}]}}`);
    return out.str_view();
}

fn String? lsp_call(Process* child, String body) {
    lsp_send(child, lsp_frame(body))!;
    return lsp_recv(child)!;
}

fn int count_substr(String text, String needle) {
    int count = 0;
    while (true) {
        sz? found = text.index_of(needle);
        if (catch found) return count;
        count++;
        text = text[found + needle.len..];
    }
}

fn bool diagnostics_count(String body, int count) {
    return count_substr(body, `"code":`) == count;
}

fn int? initialize_checks(Process* child) {
    String response = lsp_call(child, initialize("1"))!;
    if (!expect(response.contains(`"id":1`) &&
            response.contains(`"textDocumentSync":1`), "initialize Full sync")) return 1;
    if (!expect(response.contains(`"name":"rez3-lsp"`) &&
            response.contains(`"version":"0.4.0"`), "initialize serverInfo")) return 1;
    DString long_id = dstring::temp();
    for (int i = 0; i < 300; i++) long_id.append("x");
    response = lsp_call(child, initialize(string::tformat(`"%s"`, long_id.str_view())))!;
    if (!expect(response.contains(`"id":null`) && response.contains(`"code":-32600`),
            "oversized id")) return 1;
    response = lsp_call(child, initialize("1.5"))!;
    if (!expect(response.contains(`"id":1.5`), "fractional id")) return 1;
    return 0;
}

fn int? id_protocol_checks(Process* child) {
    String response = lsp_call(child, initialize("1.2345678901234567"))!;
    if (!expect(response.contains(`"id":1.2345678901234567`),
            "high precision id")) return 1;
    response = lsp_call(child, initialize("1.25e+20"))!;
    if (!expect(response.contains(`"id":1.25e+20`), "exponent id")) return 1;
    response = lsp_call(child, initialize("true"))!;
    if (!expect(response.contains(`"id":null`) && response.contains(`"code":-32600`),
            "boolean id")) return 1;
    String payload = lsp_frame(initialize(`"fragmented"`));
    lsp_send(child, payload[:payload.len / 2])!;
    thread::sleep_ms(20)!;
    lsp_send(child, payload[payload.len / 2..])!;
    response = lsp_recv(child)!;
    if (!expect(response.contains(`"id":"fragmented"`), "fragmented request")) return 1;
    return 0;
}

fn int? document_open_checks(Process* child) {
    String response = lsp_call(child, open_message(BAD_URI, BAD_TEXT, 1))!;
    if (!expect(response.contains(BAD_URI) && diagnostics_count(response, 1),
            "bad document count")) return 1;
    if (!expect(response.contains(`"code":"STRUCT"`) &&
            response.contains(`"start":{"line":0`) &&
            response.contains(`"severity":1`) && response.contains(`"source":"rez3asm"`),
            "bad document diagnostic")) return 1;
    response = lsp_call(child, open_message(GOOD_URI, GOOD_TEXT, 1))!;
    if (!expect(response.contains(GOOD_URI) && response.contains(`"diagnostics":[]`),
            "good document")) return 1;
    return 0;
}

fn int? churn(Process* child, int count) {
    for (int i = 0; i < count; i++) {
        String response = lsp_call(child, change_message(CASCADE_TEXT, 2))!;
        if (!expect(response.contains(GOOD_URI), "memory churn response")) return 1;
    }
    return 0;
}

fn int? memory_checks(Process* child) {
    if (churn(child, 32)! != 0) return 1;
    ulong before = process_memory_bytes(child)!;
    if (churn(child, 2000)! != 0) return 1;
    ulong after = process_memory_bytes(child)!;
    ulong growth = after > before ? after - before : 0;
    io::printfn("RSS before=%d, after=%d, growth=%d", before, after, growth);
    if (!expect(growth <= MEMORY_GROWTH_MAX, "memory growth over 512 KiB")) return 1;
    return 0;
}

fn int? malformed_change_checks(Process* child) {
    String[] changes = { "[]", "[{}]", "[null]", "[1]", "[[]]" };
    for (sz i = 0; i < changes.len; i++) {
        String body = string::tformat(
            `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{`
            `"textDocument":{"uri":"file:///smoke-good.rza","version":2},`
            `"contentChanges":%s}}`, changes[i]);
        lsp_send(child, lsp_frame(body))!;
    }
    String[] malformed = {
        "null", "[]",
        `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":null}`,
        `{"jsonrpc":"2.0","method":"textDocument/didChange","params":null}`,
        `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":null}}`,
        `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":[]}}`,
    };
    for (sz i = 0; i < malformed.len; i++) lsp_send(child, lsp_frame(malformed[i]))!;
    String missing = "cav m, field\nres x, m, 8\nmed x_m, x, m\n"
        "casc c: x_m -> out\nendc\nret\n";
    String response = lsp_call(child, change_message(missing, 2))!;
    if (!expect(response.contains(GOOD_URI) && diagnostics_count(response, 2) &&
            count_substr(response, `"code":"STRUCT"`) == 2,
            "malformed cascade diagnostics")) return 1;
    response = lsp_call(child, change_message(BAD_TEXT, 2))!;
    if (!expect(response.contains(GOOD_URI) && diagnostics_count(response, 1),
            "change after churn")) return 1;
    return 0;
}

fn int? close_reopen_checks(Process* child) {
    String close = `{"jsonrpc":"2.0","method":"textDocument/didClose",`
        `"params":{"textDocument":{"uri":"file:///smoke-good.rza"}}}`;
    String response = lsp_call(child, close)!;
    if (!expect(response.contains(GOOD_URI) && response.contains(`"diagnostics":[]`),
            "close diagnostics")) return 1;
    response = lsp_call(child, open_message(GOOD_URI, GOOD_TEXT, 3))!;
    if (!expect(response.contains(GOOD_URI) && response.contains(`"diagnostics":[]`),
            "reopen diagnostics")) return 1;
    return 0;
}

fn int? diagnostic_limit_checks(Process* child) {
    DString many = dstring::temp();
    for (int i = 0; i < 1002; i++) many.append("x\n");
    String response = lsp_call(child, change_message(many.str_view(), 4))!;
    if (!expect(diagnostics_count(response, 1001) &&
            response.contains("2 diagnostics suppressed"), "diagnostic summary")) return 1;
    response = lsp_call(child, change_message(GOOD_TEXT, 5))!;
    if (!expect(response.contains(`"diagnostics":[]`), "summary reset")) return 1;
    DString unicode = dstring::temp();
    for (int i = 0; i < 200; i++) unicode.append("€");
    unicode.append("\n");
    response = lsp_call(child, change_message(unicode.str_view(), 6))!;
    sz? start = response.index_of(`"message":"`);
    if (catch start) {
        expect(false, "UTF-8 diagnostic missing");
        return 1;
    }
    String rest = response[start + 11..];
    sz end = rest.index_of_char('"') ?? rest.len;
    String message = rest[:end];
    if (!expect(message.len <= 256 && !message.ends_with("�"),
            "UTF-8 diagnostic clip")) return 1;
    return 0;
}

fn int? shutdown_checks(Process* child) {
    String response = lsp_call(child,
        `{"jsonrpc":"2.0","id":2,"method":"shutdown"}`)!;
    if (!expect(response.contains(`"id":2,"result":null`), "shutdown response")) return 1;
    lsp_send(child, lsp_frame(`{"jsonrpc":"2.0","method":"exit"}`))!;
    int status = wait_process(child)!;
    if (!expect(status == 0, "LSP exit status")) return 1;
    String stderr = read_child_stderr(child)!;
    if (stderr.len > 0) io::eprintfn("server stderr:\n%s", stderr);
    return 0;
}

fn int? run_oversize(String name, String payload, String expected) {
    ProcessResult result = run_simple_input({"./rez3asm.exe", "--lsp"}, payload)!;
    if (!expect(result.status == 2 && result.stderr_text.contains(expected), name)) {
        print_result(result);
        return 1;
    }
    return 0;
}

fn int? oversize_static_checks() {
    DString header = dstring::temp();
    header.append_char_repeat('X', 9000);
    if (run_oversize("oversize header", header.str_view(), "header too large")! != 0) {
        return 1;
    }
    DString json = dstring::temp("[");
    for (int i = 0; i < 65537; i++) json.append("0,");
    json.append("0]");
    if (run_oversize("oversize JSON values", lsp_frame(json.str_view()),
            "JSON values exceeds static budget")! != 0) return 1;
    if (run_oversize("oversize body", "Content-Length: 16777217\r\n\r\n",
            "body too large")! != 0) return 1;
    return 0;
}

fn int? oversize_document_checks() {
    DString document = dstring::temp();
    document.append_char_repeat(';', 1048577);
    if (run_oversize("oversize document", lsp_frame(open_message(
            "file:///too-large.rza", document.str_view(), 1)),
            "document exceeds static budget")! != 0) return 1;
    DString uri = dstring::temp("file:///");
    uri.append_char_repeat('u', 1024);
    if (run_oversize("oversize URI", lsp_frame(open_message(uri.str_view(),
            "ret\n", 1)), "URI exceeds static budget")! != 0) return 1;
    DString slots = dstring::temp();
    for (int i = 0; i < 65; i++) {
        slots.append(lsp_frame(open_message(string::tformat("file:///slot-%d.rza", i),
            "ret\n", 1)));
    }
    if (run_oversize("oversize slots", slots.str_view(),
            "document slots exceeds static budget")! != 0) return 1;
    return 0;
}

fn int lsp_main() {
    int? status = lsp_run();
    if (catch status) {
        io::eprintn("SMOKE FAILED");
        return 1;
    }
    return status;
}

fn int? lsp_run() {
    reset_temp_dir()!;
    Process child = lsp_start()!;
    defer lsp_destroy(&child);
    if (initialize_checks(&child)! != 0) return 1;
    if (id_protocol_checks(&child)! != 0) return 1;
    lsp_send(&child, lsp_frame(`{"jsonrpc":"2.0","method":"initialized","params":{}}`))!;
    if (document_open_checks(&child)! != 0) return 1;
    if (memory_checks(&child)! != 0) return 1;
    if (malformed_change_checks(&child)! != 0) return 1;
    if (close_reopen_checks(&child)! != 0) return 1;
    if (diagnostic_limit_checks(&child)! != 0) return 1;
    if (shutdown_checks(&child)! != 0) return 1;
    if (oversize_static_checks()! != 0) return 1;
    if (oversize_document_checks()! != 0) return 1;
    path::rmtree(path::tnew("build/rza-tests")!)!;
    io::printn("SMOKE OK");
    return 0;
}
