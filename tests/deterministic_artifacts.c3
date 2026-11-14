module rza_tests;

import std::core::dstring;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::io::path;

const long OUTPUT_BYTES_MAX = 67108864;
const sz ARTIFACT_READ_BYTES_MAX = 67108864;
char[ARTIFACT_READ_BYTES_MAX] artifact_output_buf;
char[1024 * 1024] artifact_source_buf;

const String ARTIFACT_SOURCE = "cav main, field\n"
    "res x, main, 8\n"
    "med x_m, x, main\n"
    "mov %r0, 42\n"
    "store [x_m + 0], %r0\n"
    "load %r1, [x_m + 0]\n"
    "print %r1\n"
    "decay main\n"
    "ret\n";

const String TYPED_ARTIFACT_SOURCE = "layout Entry: key:i64, value:i64\n"
    "res entries, field, Entry[2]\nmed entries_m, entries, field\n"
    "mov %r0, 1\nstore [entries_m + %r0].value, %r0\n"
    "load %r1, [entries_m + 0].key\nprint %r1\nret\n";

fn String? emit_artifact(String source, String output) {
    String[] command = { compiler_path(), source, "--emit-c", "-o", output };
    ProcessResult result = run_simple(command)!;
    if (!expect(result.status == 0 && result.stdout_text.len == 0 &&
            result.stderr_text.len == 0, "artifact emit diagnostics")) {
        print_result(result);
        return TEST_ERROR~;
    }
    long size = file::get_size(output)!;
    if (!expect(size <= OUTPUT_BYTES_MAX, "generated output exceeds budget")) {
        return TEST_ERROR~;
    }
    char[] data = read_file(output, artifact_output_buf[..])!;
    return (String)data;
}

fn String? emit_lib_artifact(String source, String output) {
    String[] command = { compiler_path(), source, "--emit-lib", "-o", output };
    ProcessResult result = run_simple(command)!;
    if (!expect(result.status == 0 && result.stdout_text.len == 0 &&
            result.stderr_text.len == 0, "lib artifact emit diagnostics")) {
        print_result(result);
        return TEST_ERROR~;
    }
    char[] data = read_file(output, artifact_output_buf[..])!;
    return (String)data;
}

fn String source_prefix(String source) {
    char[sha256::HASH_SIZE] digest = sha256::hash(source);
    DString prefix = dstring::temp("/* Source-SHA256: ");
    for (sz i = 0; i < digest.len; i++) prefix.appendf("%02x", digest[i] & 0xff);
    prefix.append(" */\n");
    return prefix.str_view();
}

fn int? check_repeat_and_change() {
    String source_path = temp_path("case.rza");
    write_file(source_path, ARTIFACT_SOURCE)!;
    String first = dstring::temp(emit_artifact(source_path, temp_path("first.c"))!).str_view();
    if (!expect(first.starts_with(source_prefix(ARTIFACT_SOURCE)),
            "source hash prefix")) return 1;
    String second = emit_artifact(source_path, temp_path("second.c"))!;
    if (!expect(first == second, "repeat emit is not byte-identical")) return 1;
    DString changed = dstring::temp("; changed input\n");
    changed.append(ARTIFACT_SOURCE);
    write_file(source_path, changed.str_view())!;
    String changed_c = emit_artifact(source_path, temp_path("changed.c"))!;
    if (!expect(changed_c.starts_with(source_prefix(changed.str_view())),
            "changed source hash")) return 1;
    if (!expect(changed_c != first, "changed source did not change C")) return 1;
    return 0;
}

fn int? check_paths_and_indexed() {
    path::mkdir(path::tnew(temp_path("first-path"))!, true)!;
    path::mkdir(path::tnew(temp_path("second-path"))!, true)!;
    String one = temp_path("first-path/one.rza");
    String two = temp_path("second-path/different-name.rza");
    write_file(one, ARTIFACT_SOURCE)!;
    write_file(two, ARTIFACT_SOURCE)!;
    String first = dstring::temp(emit_artifact(one,
        temp_path("first-path/out.c"))!).str_view();
    String second = emit_artifact(two, temp_path("second-path/out.c"))!;
    if (!expect(first == second, "same bytes differ across paths")) return 1;
    write_file(one, TYPED_ARTIFACT_SOURCE)!;
    write_file(two, TYPED_ARTIFACT_SOURCE)!;
    String typed_first = emit_artifact(one, temp_path("typed-first.c"))!;
    String typed_second = emit_artifact(two, temp_path("typed-second.c"))!;
    if (!expect(typed_first == typed_second &&
            typed_first.starts_with(source_prefix(TYPED_ARTIFACT_SOURCE)),
            "typed artifact paths or hash")) return 1;
    char[] indexed = read_file("tests/indexed.rza", artifact_source_buf[..])!;
    String first_c = dstring::temp(emit_artifact("tests/indexed.rza",
        temp_path("indexed-first.c"))!).str_view();
    if (!expect(first_c.starts_with(source_prefix((String)indexed)),
            "indexed source hash")) return 1;
    String second_c = emit_artifact("tests/indexed.rza", temp_path("indexed-second.c"))!;
    if (!expect(first_c == second_c, "indexed emit is not deterministic")) return 1;
    if (!expect(first_c.contains("if ((uint64_t)r2 > 56) {") &&
            !first_c.contains("rez_cell_bounds("), "constant raw cell bounds")) return 1;
    String casc_c = emit_artifact("tests/bounds_casc_dynamic.rza",
        temp_path("bounds-casc.c"))!;
    if (!expect(casc_c.contains("if ((uint64_t)r0 > 0) {") &&
            !casc_c.contains("rez_cell_bounds("), "constant cascade bounds")) return 1;
    return 0;
}

fn int text_count(String text, String needle) {
    assert(needle.len > 0);
    int count = 0;
    String rest = text;
    while (rest.len > 0) {
        sz? found = rest.index_of(needle);
        if (catch found) break;
        count++;
        rest = rest[found + needle.len..];
    }
    return count;
}

fn int? check_prefix_hoist_artifact() {
    String generated = emit_artifact("tests/hoist_prefix.rza",
        temp_path("hoist-prefix.c"))!;
    if (!expect(text_count(generated, "rez_deref_cell(m_x_m)") == 2,
            "prefix mediator is checked once per procedure")) return 1;
    generated = emit_artifact("tests/hoist_call.rza", temp_path("hoist-call.c"))!;
    if (!expect(text_count(generated, "rez_deref_cell(m_x_m)") == 3,
            "call disables mediator hoisting")) return 1;
    return 0;
}

fn int? check_crc_dispatch_artifact() {
    String generated = emit_artifact("bench/crc32c_hw.rza",
        temp_path("crc-dispatch.c"))!;
    if (!expect(generated.contains("static void p_checksum_crc0_portable(void)") &&
            generated.contains("static void p_checksum_crc0_sse42(void)") &&
            generated.contains("rez_crc32c_u64_x86(r0"),
            "CRC procedure has portable and hardware variants")) return 1;
    return 0;
}

fn int? check_async_drain_artifact() {
    String generated = emit_artifact("tests/hoist_prefix.rza",
        temp_path("async-drain.c"))!;
    if (!expect(generated.contains("if (g_async.count != 0) (void)rez_async_drain") &&
            !generated.contains("\n    (void)rez_async_drain(&g_async);"),
            "empty async queue skips drain call")) return 1;
    return 0;
}

fn int? check_fault_helper_artifact() {
    String checked = emit_artifact("tests/checked_add_overflow.rza",
        temp_path("checked-helper.c"))!;
    if (!expect(text_count(checked, "static void rez3asm_fault(") == 1 &&
            checked.contains("[[noreturn]] static void rez3asm_fault(") &&
            checked.contains("rez3asm_fault(2, \"arithmetic overflow\", nullptr);") &&
            !checked.contains("fprintf(stderr, \"FAULT line 2: arithmetic overflow"),
            "checked overflow uses the cold helper")) return 1;
    String bounds = emit_artifact("tests/bounds_dynamic.rza",
        temp_path("bounds-helper.c"))!;
    if (!expect(bounds.contains("rez3asm_fault(6, \"out of bounds\", \"x_m\");") &&
            !bounds.contains("fprintf(stderr, \"FAULT line 6: out of bounds"),
            "dynamic bounds use the cold helper")) return 1;
    return 0;
}

fn int? check_frame_free_artifact() {
    String hello = emit_lib_artifact("tests/lib_hello.rza",
        temp_path("frame-free-hello.c"))!;
    if (!expect(hello.contains("static void p_greet(void) {") &&
            text_count(hello, "rez_frame_reset(&f_P_greet") == 1 &&
            text_count(hello, "rez_decay(&f_P_greet") == 1,
            "frame-free procedure retains one host lifecycle")) return 1;
    String ring = emit_lib_artifact("bench/ring.rza",
        temp_path("frame-free-ring.c"))!;
    if (!expect(text_count(ring, "p_push();") == 2 &&
            !ring.contains("rza_push();"),
            "internal calls bypass empty proc lifecycle")) return 1;
    String raised = emit_lib_artifact("tests/lib_raise.rza",
        temp_path("frame-owning-raise.c"))!;
    if (!expect(!raised.contains("static void p_setup(void) {") &&
            text_count(raised, "rez_frame_reset(&f_P_setup") == 1,
            "frame-owning procedure keeps the original emitter")) return 1;
    return 0;
}

fn int artifacts_main() {
    defer (void)cleanup_temp_dir();
    int? status = artifacts_run();
    if (catch status) {
        io::eprintn("DETERMINISTIC_ARTIFACTS FAILED");
        return 1;
    }
    return status;
}

fn int? artifacts_run() {
    assert(ARTIFACT_READ_BYTES_MAX == OUTPUT_BYTES_MAX);
    reset_temp_dir()!;
    if (check_repeat_and_change()! != 0) return 1;
    if (check_paths_and_indexed()! != 0) return 1;
    if (check_crc_dispatch_artifact()! != 0) return 1;
    if (check_prefix_hoist_artifact()! != 0) return 1;
    if (check_async_drain_artifact()! != 0) return 1;
    if (check_fault_helper_artifact()! != 0) return 1;
    if (check_frame_free_artifact()! != 0) return 1;
    io::printn("DETERMINISTIC_ARTIFACTS OK");
    return 0;
}
