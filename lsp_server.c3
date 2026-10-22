// ============================================================================
// lsp_server.c3 — LSP-сервер REZ3-ASM внутри транспайлера (`rez3asm --lsp`).
//
// Замена rez3-lsp.js (Node): то же минимальное подмножество LSP 3.17 —
// JSON-RPC 2.0 поверх stdio (Content-Length framing), синхронная
// валидация на didOpen/didChange (Full sync), без временных файлов:
// текст документа скармливается чекеру из памяти (run + reset_state,
// диагностика собирается viol() в lsp_diags).
//
// initialize → capabilities { textDocumentSync: 1 }, serverInfo;
// shutdown → null; exit → 0 после shutdown, иначе 1; EOF на stdin → 0.
// Неизвестный request → error -32601; уведомления без id игнорируются.
// stdout — строго протокол; логи — только stderr.
// ============================================================================
module rez3asm;

import std::io;
import std::io::file;
import libc;
import std::core::env;
import std::core::dstring;
import std::collections::map;
import std::collections::object;
import std::encoding::json;

const String LSP_VERSION = "0.4.0";

// Windows: stdin/stdout по умолчанию в текстовом режиме (CRLF↔LF ломает
// Content-Length в обе стороны) — переводим в бинарный. _setmode в std C3
// не забинден, объявляем сами; _O_BINARY = 0x8000.
extern fn CInt _setmode(CInt fd, CInt mode) @feat(WIN32);
const CInt LSP_O_BINARY @feat(WIN32) = 0x8000;

HashMap{String, String} lsp_docs;   // uri -> текст документа
bool lsp_shutdown = false;

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
    if (id.is_string()) { json_str(d, id.s); return; }
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
    DString frame = dstring::new_with_capacity(mem, body.len + 40);
    defer frame.free();
    frame.appendf("Content-Length: %d\r\n\r\n", body.len);
    frame.append_string(body);
    lsp_write(frame.str_view());
}

fn void lsp_respond(Object* id, String result_json) {
    DString d = dstring::new(mem);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","id":`);
    append_id(&d, id);
    d.append_string(`,"result":`);
    d.append_string(result_json);
    d.append_string("}");
    lsp_send_body(d.str_view());
}

fn void lsp_respond_error(Object* id, int code, String message) {
    DString d = dstring::new(mem);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","id":`);
    append_id(&d, id);
    d.appendf(`,"error":{"code":%d,"message":`, code);
    json_str(&d, message);
    d.append_string("}}");
    lsp_send_body(d.str_view());
}

// --- диагностика -----------------------------------------------------------------
fn void publish_diagnostics(String uri, bool empty) {
    DString d = dstring::new(mem);
    defer d.free();
    d.append_string(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":`);
    json_str(&d, uri);
    d.append_string(`,"diagnostics":[`);
    if (!empty) {
        foreach (i, dg : lsp_diags) {
            if (i > 0) d.append_char(',');
            int ln = dg.line - 1;           // 1-based -> 0-based
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
    lsp_send_body(d.str_view());
}

// чекер из памяти: полный сброс + один проход; нарушения — в lsp_diags.
// Временные аллокации прохода (split/cat) — из tmem, @pool возвращает их
// после публикации диагностики: иначе каждая валидация добавляла бы ~размер
// документа к RSS долгоживущего процесса.
fn void validate(String uri, String text) {
    reset_state();
    srcname = uri;
    @pool() {
        run(text);
        publish_diagnostics(uri, false);
    };
}

// --- обработчики textDocument/* ----------------------------------------------------
fn Object* lsp_text_document(Object* params) {
    if (params == null) return null;
    return params.get("textDocument") ?? null;
}

fn void on_did_open(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri_o = td.get_string("uri");
    if (catch uri_o) return;
    String text = td.get_string("text") ?? "";
    if (try cur = lsp_docs.get_ref(uri_o)) {
        cur.free(mem);              // старая копия текста — в мусор
        *cur = text.copy(mem);
    } else {
        lsp_docs.set(uri_o.copy(mem), text.copy(mem));
    }
    validate(uri_o, text);
}

fn void on_did_change(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri = td.get_string("uri");
    if (catch uri) return;
    String*? cur = lsp_docs.get_ref(uri);
    if (catch cur) return;
    Object*? changes = params.get("contentChanges");
    if (catch changes) return;
    if (!changes.is_indexable()) return;
    // Full sync: последнее change содержит весь текст
    String text = *cur;
    for (sz i = 0; i < changes.get_len(); i++) {
        Object* ch = changes.get_at(i);
        if (try t = ch.get_string("text")) text = t;
    }
    cur.free(mem);                  // старая копия текста — в мусор
    *cur = text.copy(mem);          // ключ уже в map — обновляем на месте
    validate(uri, text);
}

fn void on_did_close(Object* params) {
    Object* td = lsp_text_document(params);
    if (td == null) return;
    String? uri = td.get_string("uri");
    if (catch uri) return;
    (void)lsp_docs.remove(uri);
    publish_diagnostics(uri, true);
}

// --- диспетчер ----------------------------------------------------------------------
fn void handle_message(Object* msg) {
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
                                  cat({"method not found: ", method}));
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

// --- точка входа (--lsp) ------------------------------------------------------------------
// ВАЖНО: читаем побайтово (read_byte → fgetc). File.read — это fread(buf,N),
// который на открытом пайпе ждёт все N байт и заблокировал бы сессию после
// первого же сообщения (проявляется только интерактивно; на закрытом stdin
// fread отдаёт хвост по EOF, и всё «работало»).
fn int lsp_main() {
    $if env::WIN32:
        _setmode(libc::fileno(libc::stdin()), LSP_O_BINARY);
        _setmode(libc::fileno(libc::stdout()), LSP_O_BINARY);
    $endif
    g_lsp_mode = true;
    lsp_docs.init(mem);

    DString inbuf = dstring::new(mem);
    defer inbuf.free();
    File* in = io::stdin();
    sz header_end = -1;             // позиция "\r\n\r\n"; -1 = читаем заголовок
    int body_len = 0;
    while (true) {
        char? c = in.read_byte();
        if (catch c) break;         // EOF/ошибка stdin без exit → exit(0)
        inbuf.append_char(c);
        if (header_end < 0) {
            if (inbuf.len() < 4) continue;
            if (!inbuf.str_view().ends_with("\r\n\r\n")) continue;
            header_end = (sz)inbuf.len() - 4;
            body_len = header_content_length(inbuf.str_view()[:header_end]);
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
        Object*? msg = json::parse(mem, body);
        // буфер очищаем только после разбора: тело алиасит inbuf
        inbuf.clear();
        header_end = -1;
        if (catch msg) {
            io::eprintfn("[rez3-lsp] bad JSON-RPC payload");
            continue;
        }
        handle_message(msg);
        msg.free();
    }
    return 0;
}
