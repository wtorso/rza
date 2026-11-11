module rza_tests;

import libc;
import std::io;
import std::net::os;
import std::os::process;
import std::thread;
import std::time;

const sz LSP_CLIENT_BYTES_MAX = 4 * 1024 * 1024 + 16384;
char[LSP_CLIENT_BYTES_MAX] lsp_input_buf;
char[LSP_CLIENT_BYTES_MAX] lsp_message_buf;
char[16384] lsp_read_chunk;
sz lsp_input_len;

fn Process? lsp_start() {
    lsp_input_len = 0;
    String[] command = { "./rez3asm.exe", "--lsp" };
    SpawnOptions options = SpawnOptions.INHERIT_ENV;
    $if env::WIN32:
        options |= SpawnOptions.ASYNC_OUTPUT;
    $endif
    Process child = process::spawn(command, options)!;
    $if !env::WIN32:
        NativeSocket socket = (NativeSocket)libc::fileno(child.stdout_file);
        socket.set_non_blocking(true)!;
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

fn String? lsp_recv(Process* child) {
    Time started = time::now();
    while (true) {
        sz count = child.read_stdout(lsp_read_chunk[..].ptr, lsp_read_chunk.len)!;
        if (count > 0) {
            if (lsp_input_len + count > LSP_CLIENT_BYTES_MAX) return TEST_ERROR~;
            lsp_input_buf[lsp_input_len:count] = lsp_read_chunk[:count];
            lsp_input_len += count;
        }
        sz body_start = 0;
        sz total = lsp_frame_length(lsp_input_buf[:lsp_input_len], &body_start)!;
        if (total > 0) {
            sz body_len = total - body_start;
            lsp_message_buf[:body_len] = lsp_input_buf[body_start:body_len];
            for (sz i = total; i < lsp_input_len; i++) {
                lsp_input_buf[i - total] = lsp_input_buf[i];
            }
            lsp_input_len -= total;
            return (String)lsp_message_buf[:body_len];
        }
        if ((time::now() - started).to_ms() > 15000) {
            sz prefix_len = min(lsp_input_len, (sz)200);
            String prefix = (String)lsp_input_buf[:prefix_len];
            io::eprintfn("recv timeout: bytes=%d body_start=%d prefix=%s",
                lsp_input_len, body_start, prefix);
            child.terminate()!;
            (void)child.join();
            return TEST_ERROR~;
        }
        thread::sleep_ms(5)!;
    }
}

fn void lsp_destroy(Process* child) {
    (void)child.destroy();
}
