module rza_tests;

import libc;
import std::collections::object;
import std::encoding::json;
import std::io;
import std::io::file;
import std::net::os;
import std::os::process;
import std::os::win32;
import std::thread;
import std::time;

const sz LSP_CLIENT_BYTES_MAX = 4 * 1024 * 1024 + 16384;
char[LSP_CLIENT_BYTES_MAX] lsp_input_buf;
char[LSP_CLIENT_BYTES_MAX] lsp_message_buf;
char[16384] lsp_read_chunk;
char[65536] lsp_stderr_buf;
sz lsp_input_len;
File lsp_stderr_file;

fn Process? lsp_start() {
    lsp_input_len = 0;
    CFile raw = libc::tmpfile();
    if (raw == null) return TEST_ERROR~;
    lsp_stderr_file = file::from_handle(raw);
    String[] command = { compiler_path(), "--lsp" };
    SpawnOptions options = SpawnOptions.INHERIT_ENV;
    $if env::WIN32:
        options |= SpawnOptions.ASYNC_OUTPUT;
    $endif
    Process? maybe = process::spawn(command, options, {}, process::CAPTURE,
        process::CAPTURE, process_file(lsp_stderr_file));
    if (catch maybe) {
        (void)lsp_stderr_file.close();
        return TEST_ERROR~;
    }
    Process child = maybe;
    $if !env::WIN32:
        NativeSocket socket = (NativeSocket)libc::fileno(child.stdout_file);
        if (catch socket.set_non_blocking(true)) {
            (void)child.terminate();
            (void)child.join();
            (void)child.destroy();
            (void)lsp_stderr_file.close();
            return TEST_ERROR~;
        }
    $endif
    return child;
}

fn void? lsp_send(Process* child, String payload) {
    while (payload.len > 0) {
        sz written = child.write_stdin(payload)!;
        if (written == 0) return TEST_ERROR~;
        payload = payload[written..];
    }
}

fn sz? lsp_frame_length(char[] input, sz* body_start) {
    String text = (String)input;
    sz? marker = text.index_of("\r\n\r\n");
    if (catch marker) return 0;
    String[] lines = text[:marker].tsplit("\r\n");
    int length = -1;
    for (sz i = 0; i < lines.len; i++) {
        if (!lines[i].starts_with("Content-Length:")) continue;
        length = lines[i][15..].trim().to_int() ?? -1;
    }
    if (length < 0 || length > LSP_CLIENT_BYTES_MAX) return TEST_ERROR~;
    if (input.len < marker + 4 + (sz)length) return 0;
    *body_start = marker + 4;
    return marker + 4 + (sz)length;
}

fn String? take_buffered_message() {
    sz body_start = 0;
    sz total = lsp_frame_length(lsp_input_buf[:lsp_input_len], &body_start)!;
    if (total == 0) return "";
    sz body_len = total - body_start;
    lsp_message_buf[:body_len] = lsp_input_buf[body_start:body_len];
    for (sz i = total; i < lsp_input_len; i++) {
        lsp_input_buf[i - total] = lsp_input_buf[i];
    }
    lsp_input_len -= total;
    return (String)lsp_message_buf[:body_len];
}

fn sz? read_lsp_stdout(Process* child) {
    $if env::WIN32:
        CInt fd = libc::fileno(child.stdout_file);
        Win32_DWORD count = 0;
        Win32_OVERLAPPED overlapped = { .hEvent = child.hEventOutput };
        Win32_HANDLE handle = (Win32_HANDLE)win32::_get_osfhandle(fd);
        if (win32::readFile(handle, lsp_read_chunk[..].ptr, lsp_read_chunk.len,
                &count, &overlapped)) return count;
        Win32_DWORD error = win32::getLastError();
        if (error != win32::ERROR_IO_PENDING) {
            if (error == win32::ERROR_HANDLE_EOF) return 0;
            return TEST_ERROR~;
        }
        if (!win32::getOverlappedResult(handle, &overlapped, &count, 1)) {
            error = win32::getLastError();
            if (error == win32::ERROR_IO_INCOMPLETE) return 0;
            if (error == win32::ERROR_HANDLE_EOF) return 0;
            return TEST_ERROR~;
        }
        return count;
    $else
        return child.read_stdout(lsp_read_chunk[..].ptr, lsp_read_chunk.len);
    $endif
}

fn String? lsp_recv(Process* child) {
    Time started = time::now();
    while (true) {
        String ready = take_buffered_message()!;
        if (ready.len > 0) return ready;
        sz count = read_lsp_stdout(child)!;
        if (count > 0) {
            if (lsp_input_len + count > LSP_CLIENT_BYTES_MAX) return TEST_ERROR~;
            lsp_input_buf[lsp_input_len:count] = lsp_read_chunk[:count];
            lsp_input_len += count;
        }
        if ((time::now() - started).to_ms() > 15000) {
            sz prefix_len = min(lsp_input_len, (sz)200);
            String prefix = (String)lsp_input_buf[:prefix_len];
            io::eprintfn("recv timeout: bytes=%d prefix=%s", lsp_input_len, prefix);
            return TEST_ERROR~;
        }
        thread::sleep_ms(5)!;
    }
}

fn String? lsp_stderr_text() {
    if (lsp_stderr_file.file == null) return "";
    libc::rewind(lsp_stderr_file.file);
    char[] data = io::read_buffer_to_end(&lsp_stderr_file, lsp_stderr_buf[..])!;
    return (String)data;
}

fn void lsp_destroy(Process* child) {
    if (child.stdin_file) {
        libc::fclose(child.stdin_file);
        child.stdin_file = null;
    }
    $if env::WIN32:
        bool running = child.is_alive;
    $else
        bool running = child.child != 0;
    $endif
    if (running) {
        (void)child.terminate();
        (void)wait_process(child);
    }
    (void)child.destroy();
    if (lsp_stderr_file.file != null) (void)lsp_stderr_file.close();
    lsp_stderr_file.file = null;
}

fn Object*? json_message(String body) {
    return json::tparse(body, JsonFlavor.JSON);
}

fn Object*? json_framed(String raw) {
    sz body_start = 0;
    sz total = lsp_frame_length(raw[..], &body_start)!;
    if (total == 0 || total != raw.len) return TEST_ERROR~;
    return json_message(raw[body_start..]);
}

fn bool json_id_int(Object* message, int128 expected) {
    Object*? id = message.get("id");
    if (catch id) return false;
    return id.is_int() && id.i == expected;
}

fn bool json_id_number(Object* message, double expected) {
    Object*? id = message.get("id");
    if (catch id) return false;
    if (id.is_int()) return (double)id.i == expected;
    return id.is_float() && id.f == expected;
}

fn bool json_id_null(Object* message) {
    Object*? id = message.get("id");
    if (catch id) return false;
    return id.is_null();
}

fn bool json_error_code(Object* message, int expected) {
    Object*? error = message.get("error");
    if (catch error) return false;
    Object*? code = error.get("code");
    if (catch code) return false;
    return code.is_int() && code.i == expected;
}

fn Object*? json_diagnostics(Object* message) {
    Object* params = message.get("params")!;
    Object* diagnostics = params.get("diagnostics")!;
    if (!diagnostics.is_array()) return TEST_ERROR~;
    return diagnostics;
}
