module rza_tests;

import std::core::string::conv;
import std::io;

fn bool line_exceeds_limit(String line, sz limit) {
    assert(limit > 0);
    return conv::utf8_codepoints(line) > limit;
}

fn bool line_style_path_allowed(String path) {
    if (path.starts_with("out/") || path.starts_with("build/")) return false;
    return path.ends_with(".c3") || path.ends_with(".c") || path.ends_with(".h") ||
        path.ends_with(".sh") || path.ends_with(".md") || path.ends_with(".rza") ||
        path.ends_with(".expected") || path.ends_with(".yml") || path.ends_with(".yaml") ||
        path.ends_with(".gitignore") || path.ends_with(".gitmodules") || path == "LICENSE";
}

fn void add_line_violation(StyleViolations* out, String path, sz line, sz count) {
    if (out.count >= STYLE_VIOLATIONS_MAX) {
        out.error = true;
        return;
    }
    out.items[out.count] = { path, line, "line", count };
    out.count++;
}

fn void scan_line_style_text(String path, String text, StyleViolations* out) {
    String[] lines = text.tsplit("\n");
    for (sz i = 0; i < lines.len; i++) {
        String line = lines[i];
        if (line.len > 0 && line[line.len - 1] == '\r') line = line[:line.len - 1];
        sz count = conv::utf8_codepoints(line);
        if (count > 100) add_line_violation(out, path, i + 1, count);
    }
}

fn int scan_line_style_paths(String[] paths) {
    int status = 0;
    for (sz i = 0; i < paths.len; i++) {
        if (!line_style_path_allowed(paths[i])) continue;
        char[]? maybe_text = read_file(paths[i], style_text_buf[..]);
        if (catch maybe_text) {
            io::eprintfn("error: cannot read %s", paths[i]);
            return 2;
        }
        StyleViolations result;
        scan_line_style_text(paths[i], (String)maybe_text, &result);
        for (sz j = 0; j < result.count; j++) {
            StyleViolation item = result.items[j];
            io::printfn("%s:%d: %d codepoints", item.path, item.line, item.line_count);
        }
        if (result.count > 0) status = 1;
    }
    return status;
}

fn int source_line_style_main(String[] paths) {
    if (paths.len > 0) return scan_line_style_paths(paths);
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
    return scan_line_style_paths(found);
}
