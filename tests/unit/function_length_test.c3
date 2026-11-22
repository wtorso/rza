module rza_tests;

import std::core::dstring;
import std::io::path;

fn String c3_function(sz line_count) {
    DString text = dstring::temp();
    text.append("fn void f() {\n");
    for (sz i = 1; i < line_count - 1; i++) text.append("    work();\n");
    text.append("}");
    return text.str_view();
}

fn void assert_violation(String path, String text, sz line, sz line_count) {
    StyleViolations result;
    scan_function_text(path, text, &result);
    assert(!result.error);
    assert(result.count == 1);
    assert(result.items[0].line == line);
    assert(result.items[0].name == "f");
    assert(result.items[0].line_count == line_count);
}

fn void assert_no_violation(String path, String text) {
    StyleViolations result;
    scan_function_text(path, text, &result);
    assert(!result.error);
    assert(result.count == 0);
}

fn void function_length_70_passes_and_71_fails() @test {
    assert_no_violation("pass.c3", c3_function(70));
    assert_violation("fail.c3", c3_function(71), 1, 71);
}

fn void function_length_struct_is_not_function_body() @test {
    DString text = dstring::temp(c3_function(3));
    text.append("\nstruct Big {\n");
    for (int i = 0; i < 80; i++) text.append("    int value;\n");
    text.append("}");
    assert_no_violation("struct.c3", text.str_view());
}

fn void function_length_bash_top_level_is_not_body() @test {
    DString text = dstring::temp("f() {\n    work();\n}\n");
    text.append("for i in 1 2 3; do\n    echo x\ndone\n");
    for (int i = 0; i < 80; i++) text.append("echo top\n");
    assert_no_violation("top.sh", text.str_view());
}

fn void function_length_prototypes_are_not_bodies() @test {
    assert_no_violation("sample.c", "static int f(void);");
    assert_no_violation("sample.c3", "extern fn void f(void* value);");
    assert_no_violation("prototype.c",
        "static bool f(\n    int left,\n    int right\n);");
}

fn void function_length_multiline_signature_counts() @test {
    DString text = dstring::temp("static bool f(\n    int left,\n    int right\n) {\n");
    for (int i = 0; i < 66; i++) text.append("    return left == right;\n");
    text.append("}");
    assert_violation("multi.c", text.str_view(), 1, 71);
}

fn void function_length_c_attributes_and_public_functions() @test {
    DString attribute = dstring::temp("[[maybe_unused]] static void f(void) {\n");
    for (int i = 0; i < 69; i++) attribute.append("    work();\n");
    attribute.append("}");
    assert_violation("attribute.c", attribute.str_view(), 1, 71);
    DString passing = dstring::temp("[[maybe_unused]] static void f(void) {\n");
    for (int i = 0; i < 68; i++) passing.append("    work();\n");
    passing.append("}");
    assert_no_violation("attribute-pass.c", passing.str_view());
}

fn void function_length_one_line_does_not_consume_next() @test {
    DString text = dstring::temp("fn void f() {}\n");
    text.append(c3_function(71));
    assert_violation("next.c3", text.str_view(), 2, 71);
    assert_no_violation("one.c", "static void f(void) {}");
    assert_no_violation("one.sh", "f() {}");
}

fn void function_length_bash_whitespace_before_brace() @test {
    DString spaces = dstring::temp("f()  {\n");
    for (int i = 0; i < 69; i++) spaces.append("    work();\n");
    spaces.append("}");
    assert_violation("spaces.sh", spaces.str_view(), 1, 71);
    DString tabs = dstring::temp("f()\t{\n");
    for (int i = 0; i < 69; i++) tabs.append("    work();\n");
    tabs.append("}");
    assert_violation("tab.sh", tabs.str_view(), 1, 71);
}

fn void function_length_source_path_filter() @test {
    assert(source_path_allowed("src/pass.c3"));
    assert(source_path_allowed("tests/host/runtime_safety.c"));
    assert(!source_path_allowed("out/bad.c3"));
    assert(!source_path_allowed("build/bad.c3"));
    assert(!source_path_allowed("README.md"));
    assert(!source_path_allowed("tests/old.py"));
}

fn void function_length_unclosed_function_is_error() @test {
    StyleViolations result;
    scan_function_text("bad.c3", "fn void f() {", &result);
    assert(result.error);
    assert(result.count == 0);
}


fn void function_length_real_git_discovery_and_statuses() @test {
    reset_temp_dir()!!;
    Path original = path::cwd(mem)!!;
    defer original.free(mem);
    defer (void)cleanup_temp_dir();
    defer (void)path::chdir(original);
    path::chdir(path::tnew(temp_root_path())!!)!!;
    ProcessResult initialized = run_simple({"git", "init"})!!;
    assert(initialized.status == 0);
    path::mkdir(path::tnew("src")!!, true)!!;
    path::mkdir(path::tnew("out")!!, true)!!;
    path::mkdir(path::tnew("build")!!, true)!!;
    write_file("src/pass.c3", c3_function(70))!!;
    write_file("out/bad.c3", c3_function(71))!!;
    write_file("build/bad.c3", c3_function(71))!!;
    assert(function_style_main({}) == 0);
    write_file("src/fail.c3", c3_function(71))!!;
    assert(function_style_main({}) == 1);
    assert(function_style_main({"missing.c3"}) == 2);
}
