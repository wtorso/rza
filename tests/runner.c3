module rza_tests;

import std::io;

const sz STYLE_FILE_BYTES_MAX = 2 * 1024 * 1024;
char[STYLE_FILE_BYTES_MAX] style_text_buf;

fn int scan_style_paths(String[] paths) {
    int status = 0;
    for (sz i = 0; i < paths.len; i++) {
        if (!source_path_allowed(paths[i])) continue;
        char[]? maybe_text = read_file(paths[i], style_text_buf[..]);
        if (catch maybe_text) {
            io::eprintfn("error: cannot read %s", paths[i]);
            return 2;
        }
        StyleViolations result;
        scan_function_text(paths[i], (String)maybe_text, &result);
        if (result.error) {
            io::eprintfn("error: cannot parse %s", paths[i]);
            return 2;
        }
        for (sz j = 0; j < result.count; j++) {
            StyleViolation item = result.items[j];
            io::printfn("%s:%d: %s (%d lines)", item.path, item.line,
                item.name, item.line_count);
        }
        if (result.count > 0) status = 1;
    }
    return status;
}

fn int function_style_main(String[] paths) {
    if (paths.len > 0) return scan_style_paths(paths);
    char[65536] stdout_buf;
    char[65536] stderr_buf;
    String[] command = { "git", "ls-files", "--cached", "--others",
        "--exclude-standard", "--", "*" };
    ProcessResult? maybe = run_captured(command, stdout_buf[..], stderr_buf[..]);
    if (catch maybe) {
        io::eprintn("error: git file discovery failed");
        return 2;
    }
    ProcessResult result = maybe;
    if (result.status != 0) {
        print_result(result);
        return 2;
    }
    String[] found = result.stdout_text.tsplit("\n", skip_empty: true);
    return scan_style_paths(found);
}

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintn("usage: rza_tests COMMAND [ARGS]");
        return 2;
    }
    if (args[1] == "function-style") return function_style_main(args[2..]);
    if (args[1] == "artifacts") return artifacts_main();
    if (args[1] == "budgets") return budgets_main();
    if (args[1] == "fuzz") return fuzz_main();
    if (args[1] == "ownership") return ownership_main();
    if (args[1] == "faults") return faults_main();
    io::eprintfn("unknown command: %s", args[1]);
    return 2;
}
