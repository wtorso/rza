module rza_tests;

const sz MAX_FUNCTION_LINES = 70;
const sz STYLE_VIOLATIONS_MAX = 128;

struct StyleViolation {
    String path;
    sz line;
    String name;
    sz line_count;
}

struct StyleViolations {
    StyleViolation[STYLE_VIOLATIONS_MAX] items;
    sz count;
    bool error;
}

fn bool source_path_allowed(String path) {
    if (path.starts_with("out/") || path.starts_with("build/")) return false;
    return path.ends_with(".c3") || path.ends_with(".c") ||
        path.ends_with(".h") || path.ends_with(".sh");
}

fn bool name_char(char c, bool first) {
    if (c == '_') return true;
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    return !first && c >= '0' && c <= '9';
}

fn bool bash_declaration(String line) {
    sz? marker = line.index_of("()");
    if (catch marker) return false;
    if (marker == 0 || !name_char(line[0], true)) return false;
    for (sz i = 1; i < marker; i++) {
        if (!name_char(line[i], false)) return false;
    }
    return line[marker + 2..].trim_left().starts_with("{");
}

fn bool contains_char(String text, char c) {
    return @catch(text.index_of_char(c)) != NOT_FOUND;
}

fn bool c_declaration(String line) {
    if (line.starts_with("static_assert(")) return false;
    String rest = line;
    if (rest.starts_with("[[")) {
        sz? end = rest.index_of("]]");
        if (catch end) return false;
        rest = rest[end + 2..].trim_left();
    }
    if (rest.starts_with("static ")) rest = rest[7..].trim_left();
    sz? open = rest.index_of_char('(');
    if (catch open) return false;
    if (open == 0) return false;
    String before = rest[:open].trim_right();
    for (sz i = 0; i < before.len; i++) {
        char c = before[i];
        if (!name_char(c, false) && c != ' ' && c != '\t' && c != '*') return false;
    }
    return before.len > 0;
}

fn bool is_declaration(String path, String line) {
    if (path.ends_with(".c3")) {
        return line.starts_with("fn ") && contains_char(line, '(');
    }
    if (path.ends_with(".sh")) return bash_declaration(line);
    return c_declaration(line);
}

fn String declaration_name(String line) {
    sz open = line.index_of_char('(') ?? 0;
    String before = line[:open].trim_right();
    sz start = before.len;
    while (start > 0 && name_char(before[start - 1], false)) start--;
    return before[start..];
}

fn void add_violation(StyleViolations* out, String path, sz line,
        String name, sz count) {
    if (count <= MAX_FUNCTION_LINES) return;
    if (out.count == STYLE_VIOLATIONS_MAX) {
        out.error = true;
        return;
    }
    out.items[out.count] = { path, line, name, count };
    out.count++;
}

fn sz seek_body(String path, String[] lines, sz start, bool* has_body) {
    for (sz i = start; i < lines.len; i++) {
        if (contains_char(lines[i], '{')) {
            *has_body = true;
            return i;
        }
        if (contains_char(lines[i], ';')) return i + 1;
        if (i > start && is_declaration(path, lines[i])) return i;
    }
    return lines.len;
}

fn sz find_closing(String[] lines, sz opening, bool* closed) {
    String line = lines[opening];
    sz open = line.index_of_char('{') ?? 0;
    sz close = line.index_of_char('}') ?? line.len;
    if (close > open && close < line.len) {
        *closed = true;
        return opening;
    }
    for (sz i = opening + 1; i < lines.len; i++) {
        if (lines[i].starts_with("}")) {
            *closed = true;
            return i;
        }
    }
    return lines.len;
}

fn void scan_function_text(String path, String text, StyleViolations* out) {
    String[] lines = text.tsplit("\n");
    sz index = 0;
    while (index < lines.len && !out.error) {
        if (!is_declaration(path, lines[index])) {
            index++;
            continue;
        }
        sz start = index;
        String name = declaration_name(lines[start]);
        bool has_body = false;
        sz opening = seek_body(path, lines, start, &has_body);
        if (!has_body) {
            index = opening > start ? opening : start + 1;
            continue;
        }
        bool closed = false;
        sz closing = find_closing(lines, opening, &closed);
        if (!closed) {
            out.error = true;
            return;
        }
        add_violation(out, path, start + 1, name, closing - start + 1);
        index = closing + 1;
    }
}
