module rza_tests;

import libc;
import std::collections::list;
import std::core::dstring;
import std::io;
import std::io::file;
import std::io::path;
import std::os;
import std::os::process;
import std::thread;
import std::time;

excuse TEST_ERROR;

const sz PROCESS_OUTPUT_BYTES_MAX = 4 * 1024 * 1024;
char[PROCESS_OUTPUT_BYTES_MAX] process_stdout_buf;
char[PROCESS_OUTPUT_BYTES_MAX] process_stderr_buf;

fn String compiler_path() {
    $if env::WIN32:
        return "./build/bin/rez3asm.exe";
    $else
        return "./build/bin/rez3asm";
    $endif
}

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

fn int? wait_process(Process* child) {
    Time started = time::now();
    while (true) {
        $if env::WIN32:
            if (!child.is_running()!) return child.join()!;
        $else
            CInt status;
            Pid_t pid = posix::waitpid(child.child, &status, posix::WNOHANG);
            if (pid == child.child) {
                child.child = 0;
                child.is_alive = false;
                child.return_status = posix::wIFEXITED(status) ?
                    posix::wEXITSTATUS(status) : libc::EXIT_FAILURE;
                return child.return_status;
            }
            if (pid < 0) return TEST_ERROR~;
        $endif
        if ((time::now() - started).to_ms() > 15000) {
            child.terminate()!;
            (void)child.join();
            return TEST_ERROR~;
        }
        thread::sleep_ms(5)!;
    }
}

fn ProcessResult? run_captured_input(String[] command, String input,
        char[] stdout_buf, char[] stderr_buf) {
    CFile in_raw = libc::tmpfile();
    CFile out_raw = libc::tmpfile();
    CFile err_raw = libc::tmpfile();
    if (in_raw == null || out_raw == null || err_raw == null) return TEST_ERROR~;
    File in_file = file::from_handle(in_raw);
    File out_file = file::from_handle(out_raw);
    File err_file = file::from_handle(err_raw);
    defer (void)in_file.close();
    defer (void)out_file.close();
    defer (void)err_file.close();
    io::write_all(&in_file, input)!;
    libc::rewind(in_raw);
    Process child = process::spawn(command, SpawnOptions.INHERIT_ENV, {},
        process_file(in_file), process_file(out_file), process_file(err_file))!;
    defer (void)child.destroy();
    int status = wait_process(&child)!;
    libc::rewind(out_raw);
    libc::rewind(err_raw);
    char[] out_bytes = io::read_buffer_to_end(&out_file, stdout_buf)!;
    char[] err_bytes = io::read_buffer_to_end(&err_file, stderr_buf)!;
    return { status, (String)out_bytes, (String)err_bytes };
}

fn ProcessResult? run_captured(String[] command, char[] stdout_buf,
        char[] stderr_buf) {
    return run_captured_input(command, "", stdout_buf, stderr_buf);
}

fn ProcessResult? run_simple(String[] command) {
    return run_captured(command, process_stdout_buf[..], process_stderr_buf[..]);
}

fn ProcessResult? run_simple_input(String[] command, String input) {
    return run_captured_input(command, input, process_stdout_buf[..],
        process_stderr_buf[..]);
}

fn ProcessResult? run_program(String[] command) {
    String arch = env_or("RZA_TARGET_ARCH", "");
    if (arch.len == 0) {
        if (env_or("RZA_TARGET_LAUNCHER", "").len > 0 ||
                env_or("RZA_TARGET_LOG", "").len > 0) {
            io::eprintn("FATAL: target launcher and log require target arch");
            return TEST_ERROR~;
        }
        return run_simple(command);
    }
    List{String} wrapped;
    wrapped.init(mem);
    defer wrapped.free();
    wrapped.push("bash");
    wrapped.push("tests/target_run.sh");
    wrapped.push_all(command);
    return run_simple(wrapped.array_view());
}

fn ProcessResult? compile_c(String generated, String executable) {
    List{String} command;
    command.init(mem);
    defer command.free();
    String driver = env_or("RZA_CC_DRIVER", "");
    if (driver.len == 0) {
        String cc = env_or("CC", "zig cc");
        String cflags = env_or("CFLAGS",
            "-std=c23 -pedantic -Wall -Wextra -Werror -fsanitize=undefined "
            "-fno-sanitize-recover=undefined -I include/rza -I .");
        command.push_all(cc.tsplit(" ", skip_empty: true));
        command.push_all(cflags.tsplit(" ", skip_empty: true));
        command.push_all(env_or("LDFLAGS", "").tsplit(" ", skip_empty: true));
    } else {
        String shell = env_or("RZA_CC_SHELL", "bash");
        command.push(shell);
        command.push(driver);
    }
    command.push(generated);
    command.push("-o");
    command.push(executable);
    return run_simple(command.array_view());
}

String temp_root;

fn String temp_root_path() {
    if (temp_root.len > 0) return temp_root;
    $if env::WIN32:
        uint pid = win32::getCurrentProcessId();
    $else
        Pid_t pid = posix::getpid();
    $endif
    temp_root = string::tformat("build/rza-tests-%d", pid);
    return temp_root;
}

fn void? reset_temp_dir() {
    Path directory = path::tnew(temp_root_path())!;
    if (path::exists(directory)) path::rmtree(directory)!;
    path::mkdir(directory, true)!;
}

fn void? cleanup_temp_dir() {
    Path directory = path::tnew(temp_root_path())!;
    if (path::exists(directory)) path::rmtree(directory)!;
}

fn String temp_path(String name) {
    return string::tformat("%s/%s", temp_root_path(), name);
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

fn bool expect(bool condition, String message) {
    if (!condition) io::eprintfn("FAIL: %s", message);
    return condition;
}
