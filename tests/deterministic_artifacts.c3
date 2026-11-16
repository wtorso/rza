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

fn String artifact_function(String text, String header) {
    sz? start = text.index_of(header);
    if (catch start) return "";
    sz? end = text[start..].index_of("\n}\n");
    if (catch end) return "";
    return text[start..start + end + 3];
}

fn int mediator_deref_count(String text) {
    return text_count(text, "rez_deref_cell(m_x_m)") +
        text_count(text, "rez_deref_cell_inline(m_x_m)");
}

fn int? check_prefix_hoist_artifact() {
    String generated = emit_artifact("tests/hoist_prefix.rza",
        temp_path("hoist-prefix.c"))!;
    if (!expect(mediator_deref_count(generated) == 2,
            "prefix mediator is checked once per procedure")) return 1;
    generated = emit_artifact("tests/hoist_call.rza", temp_path("hoist-call.c"))!;
    if (!expect(mediator_deref_count(generated) == 3,
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
    String synchronous = emit_artifact("tests/hoist_prefix.rza",
        temp_path("sync-no-drain.c"))!;
    if (!expect(!synchronous.contains("g_async.count"),
            "programs without async tasks omit the queue check")) return 1;
    String library = emit_lib_artifact("bench/calls.rza",
        temp_path("sync-library-drain.c"))!;
    String core = artifact_function(library, "static void p_work(void) {");
    String wrapper = artifact_function(library, "void rza_work(void) {");
    String driver = artifact_function(library, "void rza_workload(void) {");
    String boot = artifact_function(library, "void rza_boot(void) {");
    if (!expect(!core.contains("g_async.count") &&
            wrapper.contains("    p_work();\n    if (g_async.count != 0)") &&
            wrapper.contains("rez_async_drain(&g_async);\n    rez_decay") &&
            driver.contains("g_async.count") && boot.contains("g_async.count"),
            "library cores omit only internal checks; wrappers retain them")) return 1;
    String asynchronous = emit_artifact("tests/async_fifo.rza",
        temp_path("async-drain.c"))!;
    if (!expect(asynchronous.contains("if (g_async.count != 0) (void)rez_async_drain") &&
            !asynchronous.contains("\n    (void)rez_async_drain(&g_async);"),
            "async programs retain the conditional drain call")) return 1;
    String async_proc = emit_artifact("tests/async_framefree_drain.rza",
        temp_path("async-proc-drain.c"))!;
    String async_core = artifact_function(async_proc, "static void p_framefree(void) {");
    String async_main = artifact_function(async_proc, "int main(void) {");
    if (!expect(async_core.contains("g_async.count") && async_main.contains("g_async.count"),
            "async programs retain drains in procedures and at top level")) return 1;
    String single = emit_lib_artifact("bench/async_single.rza",
        temp_path("async-single-drain.c"))!;
    String direct = artifact_function(single,
        "static uint64_t rez3asm_async_drain_single(void) {");
    if (!expect(direct.contains("success = ac_run_1(task.context);") &&
            !direct.contains("success = task.run(task.context);") &&
            single.contains(
                "uint64_t rza_await(void) { return rez3asm_async_drain_single(); }"),
            "one async callback uses a direct specialized drain")) return 1;
    String queue = emit_lib_artifact("bench/async_queue.rza",
        temp_path("async-queue-drain.c"))!;
    if (!expect(!queue.contains("rez3asm_async_drain_single") &&
            queue.contains("uint64_t rza_await(void) { return rez_async_drain(&g_async); }"),
            "multiple async callbacks retain the generic drain")) return 1;
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
    if (!expect(hello.contains("{ return rez_deref_cell(mediator); }") &&
            !hello.contains("{ return rez_deref_cell_inline(mediator); }"),
            "public deref wrapper keeps the portable helper")) return 1;
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
    String[] sources = { "tests/cascade.rza", "bench/table.rza", "bench/parser.rza" };
    for (sz i = 0; i < sources.len; i++) {
        String generated = emit_artifact(sources[i], temp_path("deref-negative.c"))!;
        if (!expect(!generated.contains("rez_deref_cell_inline("),
                "non-frame-free paths keep the original helper")) return 1;
    }
    return 0;
}

fn int? check_self_move_artifact() {
    String generated = emit_artifact("tests/mov_self.rza",
        temp_path("self-move.c"))!;
    if (!expect(!generated.contains("r0 = r0;"),
            "self move is omitted from generated C")) return 1;
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
    if (check_self_move_artifact()! != 0) return 1;
    io::printn("DETERMINISTIC_ARTIFACTS OK");
    return 0;
}
