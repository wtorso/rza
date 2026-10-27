// LSP 3.17 поверх stdio, Full sync. Чекер работает из памяти.
// stdout — протокол; stderr — логи.
// shutdown → null; exit → 0 после shutdown, иначе 1; EOF → 0.
module rez3asm;

import std::io;
import std::io::file;
import libc;
import std::core::env;
import std::core::dstring;
import std::collections::object;
import std::encoding::json;

const String LSP_VERSION = "0.4.0";
const int LSP_HEADER_MAX = 8192;
const int LSP_BODY_MAX = 16777216;
const int LSP_DOC_MAX = 1048576;
const int LSP_DOCS_MAX = 64;
const int LSP_URI_MAX = 1024;
const int LSP_DIAG_TEXT_MAX = 256;
const int LSP_RESPONSE_MAX = 4194304;
const int LSP_JSON_COMMA_MAX = 65536;

// Бинарный stdio сохраняет Content-Length на Windows.
extern fn CInt _setmode(CInt fd, CInt mode) @feat(WIN32);
const CInt LSP_O_BINARY @feat(WIN32) = 0x8000;

struct LspDoc {
    bool used;
    sz uri_len;
    sz text_len;
    char[LSP_URI_MAX] uri;
    char[LSP_DOC_MAX] text;
}

LspDoc[LSP_DOCS_MAX] lsp_docs;
bool lsp_shutdown = false;

fn int lsp_doc_find(String uri) {
    for (int i = 0; i < LSP_DOCS_MAX; i++) {
        if (!lsp_docs[i].used || lsp_docs[i].uri_len != uri.len) continue;
        if (lsp_docs[i].uri[:lsp_docs[i].uri_len] == uri) return i;
    }
    return -1;
}

fn void lsp_limit(String kind) {
    io::eprintfn("[rez3-lsp] %s exceeds static budget", kind);
    libc::exit(2);
}

fn void lsp_doc_write(int index, String uri, String text) {
    assert(index >= 0 && index < LSP_DOCS_MAX);
    if (uri.len > LSP_URI_MAX) lsp_limit("URI");
    if (text.len > LSP_DOC_MAX) lsp_limit("document");
    LspDoc* doc = &lsp_docs[index];
    doc.uri[:uri.len] = uri[..];
    doc.text[:text.len] = text[..];
    doc.uri_len = uri.len;
    doc.text_len = text.len;
    doc.used = true;
}

fn String lsp_doc_uri(int index) {
    return (String)lsp_docs[index].uri[:lsp_docs[index].uri_len];
}

fn String lsp_doc_text(int index) {
    return (String)lsp_docs[index].text[:lsp_docs[index].text_len];
}

// --- JSON-сериализация (руками: ответы маленькие и фиксированной формы) ------
fn void json_str(DString* d, String s) {
    d.append_char('"');
    foreach (c : s) {
        switch (c) {
            case '"':  d.append_string("\\\"");
            case '\\': d.append_string("\\\\");
            case '\n': d.append_string("\\n");
            case '\r': d.append_string("\\r");
            case '\t': d.append_string("\\t");
            case '\b': d.append_string("\\b");
            case '\f': d.append_string("\\f");
            default:
                if (c < 0x20) { d.appendf("\\u%04x", (int)c); }
                else { d.append_char(c); }
        }
    }
    d.append_char('"');
}

// id эхом: число или строка из запроса
fn void append_id(DString* d, Object* id) {
    if (id == null || id.is_null()) { d.append_string("null"); return; }
    if (id.is_string()) {
        json_str(d, clip_utf8(id.s, LSP_DIAG_TEXT_MAX));
        return;
    }
    d.appendf("%d", id.i);
}

// --- stdio --------------------------------------------------------------------
fn void lsp_write(String s) {
    File* out = io::stdout();
    while (s.len > 0) {
        sz? n = out.write(s);
        if (catch n) return;
        if (n == 0) return;
        s = s[n..];
    }
    if (catch err = out.flush()) return;
}

fn void lsp_send_body(String body) {
    DString header = dstring::new_with_capacity(workmem, 40);
    defer header.free();
    header.appendf("Content-Length: %d\r\n\r\n", body.len);
    lsp_write(header.str_view());
    lsp_write(body);
}

fn void lsp_respond(Object* id, String result_json) {
    DString d = dstring::new(workmem);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","id":`);
    append_id(&d, id);
    d.append_string(`,"result":`);
    d.append_string(result_json);
    d.append_string("}");
    lsp_send_body(d.str_view());
}

fn void lsp_respond_error(Object* id, int code, String message) {
    DString d = dstring::new(workmem);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","id":`);
    append_id(&d, id);
    d.appendf(`,"error":{"code":%d,"message":`, code);
    json_str(&d, clip_utf8(message, LSP_DIAG_TEXT_MAX));
    d.append_string("}}");
    lsp_send_body(d.str_view());
}

// --- диагностика -----------------------------------------------------------------
fn void publish_diagnostics(String uri, bool empty) {
    DString d = dstring::new_with_capacity(workmem, LSP_RESPONSE_MAX);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":`);
    json_str(&d, uri);
    d.append_string(`,"diagnostics":[`);
    if (!empty) {
        foreach (i, dg : lsp_diags) {
            if (i > 0) d.append_char(',');
            int ln = dg.line - 1;
            if (ln < 0) ln = 0;
            d.appendf(`{"range":{"start":{"line":%d,"character":0},`
                      +++ `"end":{"line":%d,"character":9999}},`
                      +++ `"severity":1,"source":"rez3asm","code":`, ln, ln);
            json_str(&d, dg.rule);
            d.append_string(`,"message":`);
            json_str(&d, dg.msg);
            d.append_string("}");
        }
    }
    d.append_string("]}}");
    assert(d.len() <= LSP_RESPONSE_MAX);
    lsp_send_body(d.str_view());
}

fn void validate(String uri, String text) {
    reset_state();
    srcname = uri;
    sz mark = work_arena.mark();
    defer work_arena.reset(mark);
    run(text);
    int suppressed = violations - (int)lsp_diags.len();
    if (suppressed > 0) {
        DString msg = dstring::new(workmem);
        msg.appendf("%d diagnostics suppressed", suppressed);
        lsp_diags.push({ .line = 0, .rule = "STRUCT",
                         .msg = msg.copy_str(workmem) });
    }
    publish_diagnostics(uri, false);
}

// --- обработчики textDocument/* ----------------------------------------------------
fn Object* lsp_text_document(Object* params) {
    if (params == null || !params.is_keyable()) return null;
    Object* td = params.get("textDocument") ?? null;
    if (td == null || !td.is_keyable()) return null;
    return td;
}

fn void on_did_open(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri_o = td.get_string("uri");
    if (catch uri_o) return;
    String text = td.get_string("text") ?? "";
    int index = lsp_doc_find(uri_o);
    if (index < 0) {
        for (int i = 0; i < LSP_DOCS_MAX; i++) {
            if (!lsp_docs[i].used) { index = i; break; }
        }
    }
    if (index < 0) lsp_limit("document slots");
    lsp_doc_write(index, uri_o, text);
    validate(lsp_doc_uri(index), lsp_doc_text(index));
}

fn void on_did_change(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri = td.get_string("uri");
    if (catch uri) return;
    int index = lsp_doc_find(uri);
    if (index < 0) return;
    Object*? changes = params.get("contentChanges");
    if (catch changes) return;
    if (!changes.is_indexable()) return;
    String text = "";
    bool has_text = false;
    for (sz i = 0; i < changes.get_len(); i++) {
        Object* ch = changes.get_at(i);
        if (ch == null || !ch.is_keyable()) continue;
        if (try t = ch.get_string("text")) { text = t; has_text = true; }
    }
    if (!has_text) return;
    lsp_doc_write(index, uri, text);
    validate(lsp_doc_uri(index), lsp_doc_text(index));
}

fn void on_did_close(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri = td.get_string("uri");
    if (catch uri) return;
    int index = lsp_doc_find(uri);
    if (index >= 0) {
        lsp_docs[index].used = false;
        lsp_docs[index].uri_len = 0;
        lsp_docs[index].text_len = 0;
    }
    publish_diagnostics(uri, true);
}

// --- диспетчер ----------------------------------------------------------------------
fn void handle_message(Object* msg) {
    if (msg == null || !msg.is_keyable()) return;
    Object* id = null;
    if (try i = msg.get("id")) id = i;
    String method = msg.get_string("method") ?? "";
    if (method.len == 0) return;   // ответ клиента: мы не шлём server->client запросов
    Object* params = null;
    if (try p = msg.get("params")) params = p;

    switch (method) {
        case "initialize":
            lsp_respond(id,
                `{"capabilities":{"textDocumentSync":1},`
                +++ `"serverInfo":{"name":"rez3-lsp","version":"` +++ LSP_VERSION +++ `"}}`);
        case "initialized":
            break;
        case "textDocument/didSave":
            break;                  // валидация и так на change
        case "shutdown":
            lsp_shutdown = true;
            lsp_respond(id, "null");
        case "exit":
            libc::exit(lsp_shutdown ? 0 : 1);
        case "textDocument/didOpen":
            on_did_open(params);
        case "textDocument/didChange":
            on_did_change(params);
        case "textDocument/didClose":
            on_did_close(params);
        default:
            if (id != null) {
                lsp_respond_error(id, -32601,
                                  cat({"method not found: ",
                                       clip_utf8(method, LSP_DIAG_TEXT_MAX)}));
            }
    }
}

// --- Content-Length framing -----------------------------------------------------------
fn bool starts_with_icase(String s, String prefix) {
    if (s.len < prefix.len) return false;
    for (usz i = 0; i < prefix.len; i++) {
        char a = s[i];
        char b = prefix[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return false;
    }
    return true;
}

fn int header_content_length(String header) {
    int result = -1;
    String rest = header;
    while (rest.len > 0) {
        String line = rest;
        if (try eol = rest.index_of("\r\n")) {
            line = rest[:eol];
            rest = rest[eol + 2..];
        } else {
            rest = "";
        }
        if (starts_with_icase(line, "Content-Length:")) {
            result = line[15..].trim().to_int() ?? -1;
        }
    }
    return result;
}

// Ограничиваем дерево до вызова parser, который разворачивает OUT_OF_MEMORY.
fn bool lsp_json_size_ok(String body) {
    int commas = 0;
    bool in_string = false;
    bool escaped = false;
    bool line_comment = false;
    bool block_comment = false;
    for (sz i = 0; i < body.len; i++) {
        char c = body[i];
        if (line_comment) {
            if (c == '\n' || c == '\r') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (c == '*' && i + 1 < body.len && body[i + 1] == '/') {
                block_comment = false;
                i++;
            }
            continue;
        }
        if (in_string) {
            if (escaped) { escaped = false; continue; }
            if (c == '\\') { escaped = true; continue; }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') { in_string = true; continue; }
        if (c == '/' && i + 1 < body.len) {
            if (body[i + 1] == '/') { line_comment = true; i++; continue; }
            if (body[i + 1] == '*') { block_comment = true; i++; continue; }
        }
        if (c == ',') {
            commas++;
            if (commas > LSP_JSON_COMMA_MAX) return false;
        }
    }
    return true;
}

// --- точка входа (--lsp) ------------------------------------------------------------------
// Читаем побайтово: fread(buf, N) ждёт N байт на открытом пайпе.
fn int lsp_main() {
    $if env::WIN32:
        _setmode(libc::fileno(libc::stdin()), LSP_O_BINARY);
        _setmode(libc::fileno(libc::stdout()), LSP_O_BINARY);
    $endif
    g_lsp_mode = true;
    for (int i = 0; i < LSP_DOCS_MAX; i++) lsp_docs[i].used = false;

    DString inbuf = dstring::new_with_capacity(
        mem, LSP_BODY_MAX + LSP_HEADER_MAX);
    File* in = io::stdin();
    sz header_end = -1;             // позиция "\r\n\r\n"; -1 = читаем заголовок
    int body_len = 0;
    while (true) {
        char? c = in.read_byte();
        if (catch c) break;         // EOF/ошибка stdin без exit → exit(0)
        inbuf.append_char(c);
        if (header_end < 0) {
            if (inbuf.len() > (sz)LSP_HEADER_MAX) {
                io::eprintfn("[rez3-lsp] header too large");
                return 2;
            }
            if (inbuf.len() < 4) continue;
            if (!inbuf.str_view().ends_with("\r\n\r\n")) continue;
            header_end = (sz)inbuf.len() - 4;
            body_len = header_content_length(inbuf.str_view()[:header_end]);
            if (body_len > LSP_BODY_MAX) {
                io::eprintfn("[rez3-lsp] body too large");
                return 2;
            }
            if (body_len < 0) {
                // битый заголовок: отбрасываем байт и ресинхронизируемся
                inbuf.delete(0, 1);
                header_end = -1;
            }
            continue;
        }
        if ((sz)inbuf.len() < header_end + 4 + body_len) continue;
        String view = inbuf.str_view();
        String body = view[header_end + 4 .. header_end + 3 + body_len];
        if (!lsp_json_size_ok(body)) lsp_limit("JSON values");
        sz mark = work_arena.mark();
        Object*? msg = json::parse(workmem, body);
        inbuf.clear();
        header_end = -1;
        if (catch msg) {
            io::eprintfn("[rez3-lsp] bad JSON-RPC payload");
            work_arena.reset(mark);
            continue;
        }
        handle_message(msg);
        msg.free();
        work_arena.reset(mark);
    }
    return 0;
}
