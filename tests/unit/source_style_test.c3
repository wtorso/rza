module rza_tests;

import std::core::dstring;

fn void line_style_ascii_boundaries() @test {
    DString text = dstring::temp();
    defer text.free();
    text.append_char_repeat('a', 100);
    assert(!line_exceeds_limit(text.str_view(), 100));
    text.append_char('a');
    assert(line_exceeds_limit(text.str_view(), 100));
}

fn void line_style_counts_codepoints_not_bytes() @test {
    DString text = dstring::temp();
    defer text.free();
    for (int i = 0; i < 100; i++) text.append("д");
    assert(!line_exceeds_limit(text.str_view(), 100));
    text.append("д");
    assert(line_exceeds_limit(text.str_view(), 100));
}

fn void line_style_reports_file_and_line() @test {
    StyleViolations result;
    scan_line_style_text("example.md", "short\nдлинная строка\n", &result);
    assert(!result.error);
    assert(result.count == 0);
    DString text = dstring::temp("first\n");
    defer text.free();
    text.append_char_repeat('x', 101);
    scan_line_style_text("example.md", text.str_view(), &result);
    assert(result.count == 1);
    assert(result.items[0].path == "example.md");
    assert(result.items[0].line == 2);
    assert(result.items[0].line_count == 101);
}
