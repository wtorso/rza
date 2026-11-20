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

const String VIEW_ARTIFACT_SOURCE = "res raw, field, 16\nmed raw_m, raw, field\n"
    "mov %r0, 8\nview dynamic_m, raw_m, 0, %r0\n"
    "load %r1, [dynamic_m + 0]\nprint %r1\nret\n";

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
    write_file(one, VIEW_ARTIFACT_SOURCE)!;
    write_file(two, VIEW_ARTIFACT_SOURCE)!;
    String view_first = emit_artifact(one, temp_path("view-first.c"))!;
    String view_second = emit_artifact(two, temp_path("view-second.c"))!;
    if (!expect(view_first == view_second &&
            view_first.starts_with(source_prefix(VIEW_ARTIFACT_SOURCE)) &&
            view_first.contains("rez_view_cell(") &&
            view_first.contains("rez_cell_bounds(m_dynamic_m, 0, 8)"),
            "view artifact paths, hash, or dynamic bounds")) return 1;
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
    if (!expect(generated.contains("static bool p_checksum_crc0_portable(void)") &&
            generated.contains("static bool p_checksum_crc0_sse42(void)") &&
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
    String core = artifact_function(library, "static bool p_work(void) {");
    String wrapper = artifact_function(library, "RzaResult rza_work(void) {");
    String driver = artifact_function(library, "static bool p_workload(void) {");
    String boot = artifact_function(library, "static bool rez3asm_boot(void) {");
    if (!expect(!core.contains("g_async.count") &&
            wrapper.contains("    (void)p_work();\n    if (g_async.count != 0)") &&
            wrapper.contains("rez_async_drain(&g_async);") && wrapper.contains("rez_decay") &&
            driver.contains("g_async.count") && boot.contains("g_async.count"),
            "library cores omit internal checks; wrappers retain them")) return 1;
    String asynchronous = emit_artifact("tests/async_fifo.rza",
        temp_path("async-drain.c"))!;
    if (!expect(asynchronous.contains("if (g_async.count != 0) (void)rez_async_drain") &&
            !asynchronous.contains("\n    (void)rez_async_drain(&g_async);"),
            "async programs retain the conditional drain call")) return 1;
    String async_proc = emit_artifact("tests/async_framefree_drain.rza",
        temp_path("async-proc-drain.c"))!;
    String async_core = artifact_function(async_proc, "static bool p_framefree(void) {");
    String async_main = artifact_function(async_proc, "static bool rez3asm_main(void) {");
    if (!expect(async_core.contains("g_async.count") && async_main.contains("g_async.count"),
            "async programs retain drains in procedures and at top level")) return 1;
    String single = emit_lib_artifact("bench/async_single.rza",
        temp_path("async-single-drain.c"))!;
    String direct = artifact_function(single, "rez3asm_async_drain_single(void) {");
    if (!expect(direct.contains("status = ac_run_1(task.context);") &&
            !direct.contains("status = task.run(task.context);") &&
            single.contains("RzaAwaitResult drained = rez3asm_async_drain_single();"),
            "one async callback uses a direct specialized drain")) return 1;
    String queue = emit_lib_artifact("bench/async_queue.rza",
        temp_path("async-queue-drain.c"))!;
    if (!expect(!queue.contains("rez3asm_async_drain_single") &&
            queue.contains("RzaAwaitResult drained = rez_async_drain(&g_async);"),
            "multiple async callbacks retain the generic drain")) return 1;
    return 0;
}

fn int? check_fault_helper_artifact() {
    String checked = emit_artifact("tests/checked_add_overflow.rza",
        temp_path("checked-helper.c"))!;
    if (!expect(text_count(checked, "static void rez3asm_fault(") == 1 &&
            !checked.contains("[[noreturn]]") &&
            checked.contains("rez3asm_fault(RZA_FAULT_ARITHMETIC_OVERFLOW, 2,") &&
            !checked.contains("fprintf(stderr, \"FAULT line 2: arithmetic overflow"),
            "checked overflow uses the cold helper")) return 1;
    String bounds = emit_artifact("tests/bounds_dynamic.rza",
        temp_path("bounds-helper.c"))!;
    if (!expect(bounds.contains("rez3asm_fault(RZA_FAULT_OUT_OF_BOUNDS, 6,") &&
            !bounds.contains("fprintf(stderr, \"FAULT line 6: out of bounds"),
            "dynamic bounds use the cold helper")) return 1;
    String asynchronous = emit_artifact("tests/async_repeat.rza",
        temp_path("async-cold-helpers.c"))!;
    if (!expect(asynchronous.contains("rez3asm_fault(RZA_FAULT_ARENA, 1, \"cell\", \"x\");") &&
            asynchronous.contains("rez3asm_fault(RZA_FAULT_FRAME, 0,") &&
            asynchronous.contains("rez3asm_fault(RZA_FAULT_ASYNC_PENDING, 5,") &&
            asynchronous.contains("rez3asm_fault(RZA_FAULT_ARENA, 5, \"out\", \"out\");") &&
            asynchronous.contains("rez3asm_fault(RZA_FAULT_ASYNC_QUEUE, 5,") &&
            asynchronous.contains("rez3asm_abort(5, \"bump\", \"x_m\");") &&
            !asynchronous.contains("fprintf(stderr, \"FAULT line 5:") &&
            !asynchronous.contains("fprintf(stderr, \"ABORT line 5:"),
            "async ownership and queue diagnostics use cold helpers")) return 1;
    String library = emit_lib_artifact("tests/lib_result.rza",
        temp_path("controlled-library.c"))!;
    if (!expect(!library.contains("exit(") && !library.contains("fprintf(") &&
            library.contains("RzaResult rza_fail(void)"),
            "library returns faults without process output or termination")) return 1;
    return 0;
}

fn int? check_frame_free_artifact() {
    String hello = emit_lib_artifact("tests/lib_hello.rza",
        temp_path("frame-free-hello.c"))!;
    if (!expect(hello.contains("static bool p_greet(void) {") &&
            text_count(hello, "rez_frame_reset(&f_P_greet") == 1 &&
            text_count(hello, "rez_decay(&f_P_greet") == 2,
            "frame-free host cleans its frame on success and fault")) return 1;
    if (!expect(hello.contains("{ return rez_deref_cell(mediator); }") &&
            !hello.contains("{ return rez_deref_cell_inline(mediator); }"),
            "public deref wrapper keeps the portable helper")) return 1;
    String ring = emit_lib_artifact("bench/ring.rza",
        temp_path("frame-free-ring.c"))!;
    if (!expect(text_count(ring, "if (!p_push()) goto rza_fault;") == 1 &&
            !ring.contains("rza_push();"),
            "internal calls bypass empty proc lifecycle")) return 1;
    String raised = emit_lib_artifact("tests/lib_raise.rza",
        temp_path("frame-owning-raise.c"))!;
    if (!expect(raised.contains("static bool p_setup(void) {") &&
            raised.contains("RzaResult rza_setup(void) {") &&
            text_count(raised, "rez_frame_reset(&f_P_setup") == 1,
            "frame-owning procedure keeps core and host wrappers separate")) return 1;
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
    if (check_numeric8_artifact()! != 0) return 1;
    io::printn("DETERMINISTIC_ARTIFACTS OK");
    return 0;
}

fn String artifact_body(String text) {
    sz? newline = text.index_of_char('\n');
    if (catch newline) return "";
    return text[newline + 1..];
}

fn int? check_numeric8_artifact() {
    DString source = dstring::temp("cav main, field\nres raw, main, 2\n"
        "med raw_m, raw, main\nmov.i8 %r0, 0x80\nstore.i8 [raw_m + 0], %r0\n"
        "load.i8 %r1, [raw_m + 0]\nadd.i8 %r1, %r1, 1\n"
        "mov.u8 %r2, 2\ncadd.u8 %r2, %r2, 3\ndiv.i8 %r3, %r1, 2\n"
        "shl.u8 %r4, %r2, 1\nprint %r3\nret\n");
    path::mkdir(path::tnew(temp_path("numeric8-first"))!, true)!;
    path::mkdir(path::tnew(temp_path("numeric8-second"))!, true)!;
    String first_source = temp_path("numeric8-first/input.rza");
    String second_source = temp_path("numeric8-second/renamed.rza");
    write_file(first_source, source.str_view())!;
    write_file(second_source, source.str_view())!;
    String first = dstring::temp(emit_artifact(first_source,
        temp_path("numeric8-first/output.c"))!).str_view();
    String second = emit_artifact(second_source, temp_path("numeric8-second/output.c"))!;
    if (!expect(first == second && first.starts_with(source_prefix(source.str_view())),
            "numeric8 artifact repeat/path hash")) return 1;
    String[] required = {
        "rez_i8_from_bits", "rez_i8_add", "rez_u8_cadd",
        "rez_i8_div_invalid", "rez_shift8_invalid", "rez_u8_shl",
    };
    foreach (needle : required) {
        if (!expect(first.contains(needle), "numeric8 artifact semantic helper")) return 1;
    }
    String legacy_source = "res raw, field, 2\nmed raw_m, raw, field\n"
        "mov %r0, 255\nstoreb [raw_m + 0], %r0\nloadb %r1, [raw_m + 0]\n"
        "print %r1\nret\n";
    String typed_source = "res raw, field, 2\nmed raw_m, raw, field\n"
        "mov %r0, 255\nstore.u8 [raw_m + 0], %r0\nload.u8 %r1, [raw_m + 0]\n"
        "print %r1\nret\n";
    write_file(temp_path("legacy-byte.rza"), legacy_source)!;
    String legacy = emit_artifact(temp_path("legacy-byte.rza"), temp_path("legacy-byte.c"))!;
    write_file(temp_path("typed-byte.rza"), typed_source)!;
    String typed = emit_artifact(temp_path("typed-byte.rza"), temp_path("typed-byte.c"))!;
    if (!expect(artifact_body(legacy) == artifact_body(typed),
            "legacy and typed byte access bodies differ")) return 1;
    return 0;
}
