module rza_tests;

import libc;
import std::core::dstring;
import std::io;
import std::io::file;
import std::io::path;
import std::os;
import std::os::process;

excuse TEST_ERROR;

struct ProcessResult {
    int status;
    String stdout_text;
    String stderr_text;
}

fn ProcessStdio process_file(File file) {
    $if env::WIN32:
        return process::bind((Win32_HANDLE)win32::_get_osfhandle(file.fd()));
    $else
        return process::bind(file.fd());
    $endif
}

fn ProcessResult? run_captured(String[] command, char[] stdout_buf,
        char[] stderr_buf) {
    CFile out_raw = libc::tmpfile();
    CFile err_raw = libc::tmpfile();
    if (out_raw == null || err_raw == null) return TEST_ERROR~;
    File out_file = file::from_handle(out_raw);
    File err_file = file::from_handle(err_raw);
    defer (void)out_file.close();
    defer (void)err_file.close();
    Process child = process::spawn(command, SpawnOptions.INHERIT_ENV, {},
        process::CAPTURE, process_file(out_file), process_file(err_file))!;
    defer (void)child.destroy();
    int status = child.join()!;
    libc::rewind(out_raw);
    libc::rewind(err_raw);
    char[] out_bytes = io::read_buffer_to_end(&out_file, stdout_buf)!;
    char[] err_bytes = io::read_buffer_to_end(&err_file, stderr_buf)!;
    return { status, (String)out_bytes, (String)err_bytes };
}

fn void? reset_temp_dir() {
    Path directory = path::tnew("build/rza-tests")!;
    if (path::exists(directory)) path::rmtree(directory)!;
    path::mkdir(directory, true)!;
}

fn String temp_path(String name) {
    return string::tformat("build/rza-tests/%s", name);
}

fn char[]? read_file(String path, char[] buffer) {
    return file::load_buffer(path, buffer);
}

fn void? write_file(String path, String text) {
    file::save(path, text)!;
}

fn String env_or(String name, String fallback) {
    ZString value = libc::getenv(name.zstr_tcopy());
    return value == null ? fallback : value.str_view();
}

fn String normalize_lines(String text) {
    DString result = dstring::temp();
    for (sz i = 0; i < text.len; i++) {
        if (text[i] != '\r') result.append(text[i]);
    }
    while (result.len() > 0 && result.str_view()[^1] == '\n') {
        result.chop(result.len() - 1);
    }
    return result.str_view();
}

fn void print_result(ProcessResult result) {
    io::eprintfn("exit=%d\nstdout:\n%s\nstderr:\n%s", result.status,
        result.stdout_text, result.stderr_text);
}
