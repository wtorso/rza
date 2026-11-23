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
    char[] indexed = read_file("tests/fixtures/core/indexed.rza", artifact_source_buf[..])!;
    String first_c = dstring::temp(emit_artifact("tests/fixtures/core/indexed.rza",
        temp_path("indexed-first.c"))!).str_view();
    if (!expect(first_c.starts_with(source_prefix((String)indexed)),
            "indexed source hash")) return 1;
    String second_c = emit_artifact("tests/fixtures/core/indexed.rza",
        temp_path("indexed-second.c"))!;
    if (!expect(first_c == second_c, "indexed emit is not deterministic")) return 1;
    if (!expect(first_c.contains("if ((uint64_t)r2 > 56) {") &&
            !first_c.contains("rez_cell_bounds("), "constant raw cell bounds")) return 1;
    String casc_c = emit_artifact("tests/fixtures/core/bounds_casc_dynamic.rza",
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
    String generated = emit_artifact("tests/fixtures/core/hoist_prefix.rza",
        temp_path("hoist-prefix.c"))!;
    if (!expect(mediator_deref_count(generated) == 2,
            "prefix mediator is checked once per procedure")) return 1;
    generated = emit_artifact("tests/fixtures/core/hoist_call.rza", temp_path("hoist-call.c"))!;
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
    String synchronous = emit_artifact("tests/fixtures/core/hoist_prefix.rza",
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
    String asynchronous = emit_artifact("tests/fixtures/async/async_fifo.rza",
        temp_path("async-drain.c"))!;
    if (!expect(asynchronous.contains("if (g_async.count != 0) (void)rez_async_drain") &&
            !asynchronous.contains("\n    (void)rez_async_drain(&g_async);"),
            "async programs retain the conditional drain call")) return 1;
    String async_proc = emit_artifact("tests/fixtures/async/async_framefree_drain.rza",
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
    String checked = emit_artifact("tests/fixtures/core/checked_add_overflow.rza",
        temp_path("checked-helper.c"))!;
    if (!expect(text_count(checked, "static void rez3asm_fault(") == 1 &&
            !checked.contains("[[noreturn]]") &&
            checked.contains("rez3asm_fault(RZA_FAULT_ARITHMETIC_OVERFLOW, 2,") &&
            !checked.contains("fprintf(stderr, \"FAULT line 2: arithmetic overflow"),
            "checked overflow uses the cold helper")) return 1;
    String bounds = emit_artifact("tests/fixtures/core/bounds_dynamic.rza",
        temp_path("bounds-helper.c"))!;
    if (!expect(bounds.contains("rez3asm_fault(RZA_FAULT_OUT_OF_BOUNDS, 6,") &&
            !bounds.contains("fprintf(stderr, \"FAULT line 6: out of bounds"),
            "dynamic bounds use the cold helper")) return 1;
    String asynchronous = emit_artifact("tests/fixtures/async/async_repeat.rza",
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
    String library = emit_lib_artifact("tests/fixtures/library/lib_result.rza",
        temp_path("controlled-library.c"))!;
    if (!expect(!library.contains("exit(") && !library.contains("fprintf(") &&
            library.contains("RzaResult rza_fail(void)"),
            "library returns faults without process output or termination")) return 1;
    return 0;
}

fn int? check_frame_free_artifact() {
    String hello = emit_lib_artifact("tests/fixtures/library/lib_hello.rza",
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
    String raised = emit_lib_artifact("tests/fixtures/library/lib_raise.rza",
        temp_path("frame-owning-raise.c"))!;
    if (!expect(raised.contains("static bool p_setup(void) {") &&
            raised.contains("RzaResult rza_setup(void) {") &&
            text_count(raised, "rez_frame_reset(&f_P_setup") == 1,
            "frame-owning procedure keeps core and host wrappers separate")) return 1;
    String[] sources = {
        "tests/fixtures/cascades/cascade.rza", "bench/table.rza", "bench/parser.rza"
    };
    for (sz i = 0; i < sources.len; i++) {
        String generated = emit_artifact(sources[i], temp_path("deref-negative.c"))!;
        if (!expect(!generated.contains("rez_deref_cell_inline("),
                "non-frame-free paths keep the original helper")) return 1;
    }
    return 0;
}

fn int? check_self_move_artifact() {
    String generated = emit_artifact("tests/fixtures/core/mov_self.rza",
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
    if (check_numeric16_artifact()! != 0) return 1;
    if (check_numeric32_artifact()! != 0) return 1;
    if (check_numeric64_artifact()! != 0) return 1;
    if (check_float_profile_artifact()! != 0) return 1;
    if (check_float_memory_artifact()! != 0) return 1;
    if (check_float_fault_artifacts()! != 0) return 1;
    if (check_float_fault_mutations()! != 0) return 1;
    if (check_float_rhs_mutations()! != 0) return 1;
    if (check_numeric64_fault_abi()! != 0) return 1;
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


fn int? check_numeric16_artifact() {
    DString source = dstring::temp("cav main, field\nres raw, main, 4\n"
        "med raw_m, raw, main\nmov.i16 %r0, 0x8000\nstore.i16 [raw_m + 1], %r0\n"
        "load.i16 %r1, [raw_m + 1]\nadd.i16 %r1, %r1, 1\n"
        "mov.u16 %r2, 2\ncadd.u16 %r2, %r2, 3\ndiv.i16 %r3, %r1, 2\n"
        "shl.u16 %r4, %r2, 1\nprint %r3\nret\n");
    path::mkdir(path::tnew(temp_path("numeric16-first"))!, true)!;
    path::mkdir(path::tnew(temp_path("numeric16-second"))!, true)!;
    String first_source = temp_path("numeric16-first/input.rza");
    String second_source = temp_path("numeric16-second/renamed.rza");
    write_file(first_source, source.str_view())!;
    write_file(second_source, source.str_view())!;
    String first = dstring::temp(emit_artifact(first_source,
        temp_path("numeric16-first/output.c"))!).str_view();
    String second = emit_artifact(second_source, temp_path("numeric16-second/output.c"))!;
    if (!expect(first == second && first.starts_with(source_prefix(source.str_view())),
            "numeric16 artifact repeat/path hash")) return 1;
    String[] required = {
        "memcpy(&value, (char*)p + 1, 2)", "memcpy((char*)p + 1, &value, 2)",
        "r1 = rez_i16_from_bits(value)",
        "rez_i16_add", "rez_u16_cadd", "rez_i16_div_invalid",
        "rez_shift16_invalid", "rez_u16_shl",
    };
    foreach (needle : required) {
        if (!expect(first.contains(needle), "numeric16 artifact semantic helper")) return 1;
    }
    return 0;
}

fn int? check_numeric32_artifact() {
    DString source = dstring::temp("cav main, field\nres raw, main, 8\n"
        "med raw_m, raw, main\nmov.i32 %r0, 0x80000000\nstore.i32 [raw_m + 1], %r0\n"
        "load.i32 %r1, [raw_m + 1]\nadd.i32 %r1, %r1, 1\n"
        "mov.u32 %r2, 2\ncadd.u32 %r2, %r2, 3\ndiv.i32 %r3, %r1, 2\n"
        "shl.u32 %r4, %r2, 1\nprint %r3\nret\n");
    path::mkdir(path::tnew(temp_path("numeric32-first"))!, true)!;
    path::mkdir(path::tnew(temp_path("numeric32-second"))!, true)!;
    String first_source = temp_path("numeric32-first/input.rza");
    String second_source = temp_path("numeric32-second/renamed.rza");
    write_file(first_source, source.str_view())!;
    write_file(second_source, source.str_view())!;
    String first = dstring::temp(emit_artifact(first_source,
        temp_path("numeric32-first/output.c"))!).str_view();
    String second = emit_artifact(second_source, temp_path("numeric32-second/output.c"))!;
    if (!expect(first == second && first.starts_with(source_prefix(source.str_view())),
            "numeric32 artifact repeat/path hash")) return 1;
    String[] exact_access = {
        "memcpy(&value, (char*)p + 1, 4)", "memcpy((char*)p + 1, &value, 4)",
        "r1 = rez_i32_from_bits(value)",
    };
    foreach (needle : exact_access) {
        if (!expect(first.contains(needle), "numeric32 artifact exact four-byte access")) {
            return 1;
        }
    }
    String[] guards = {
        "rez_i32_add", "rez_u32_cadd", "rez_i32_div_invalid",
        "rez_shift32_invalid", "rez_u32_shl",
    };
    foreach (needle : guards) {
        if (!expect(first.contains(needle), "numeric32 artifact semantic guard")) return 1;
    }
    return 0;
}

fn int? check_numeric64_artifact() {
    DString source = dstring::temp("cav main, field\nres raw, main, 16\n"
        "med raw_m, raw, main\nmov.u64 %r0, 0xffffffffffffffff\nstore.u64 [raw_m + 1], %r0\n"
        "load.u64 %r1, [raw_m + 1]\nadd.i64 %r1, %r1, 1\n"
        "mov.u64 %r2, 2\ncadd.u64 %r2, %r2, 3\ndiv.i64 %r3, %r1, 2\n"
        "shl.u64 %r4, %r2, 1\nprint %r3\nret\n");
    path::mkdir(path::tnew(temp_path("numeric64-first"))!, true)!;
    path::mkdir(path::tnew(temp_path("numeric64-second"))!, true)!;
    String first_source = temp_path("numeric64-first/input.rza");
    String second_source = temp_path("numeric64-second/renamed.rza");
    write_file(first_source, source.str_view())!;
    write_file(second_source, source.str_view())!;
    String first = dstring::temp(emit_artifact(first_source,
        temp_path("numeric64-first/output.c"))!).str_view();
    String second = emit_artifact(second_source, temp_path("numeric64-second/output.c"))!;
    if (!expect(first == second && first.starts_with(source_prefix(source.str_view())),
            "numeric64 artifact repeat/path hash")) return 1;
    String[] exact_access = {
        "memcpy(&value, (char*)p + 1, 8)", "memcpy((char*)p + 1, &r0, 8)",
        "r1 = rez_u64_from_bits(value)",
    };
    foreach (needle : exact_access) {
        if (!expect(first.contains(needle), "numeric64 artifact exact eight-byte access")) {
            return 1;
        }
    }
    String[] guards = {
        "rez_i64_add", "rez_u64_cadd", "rez_i64_div_invalid",
        "rez_shift64_invalid", "rez_u64_shl",
    };
    foreach (needle : guards) {
        if (!expect(first.contains(needle), "numeric64 artifact semantic guard")) return 1;
    }
    return 0;
}


struct Numeric64FaultCase {
    String name;
    String code;
    int line;
    String cell;
    String out_cell;
    int guard_offset;
}

fn int? check_numeric64_fault_case(Numeric64FaultCase item) {
    String source = string::tformat("tests/fixtures/numeric64/%s.rza", item.name);
    String generated = temp_path(string::tformat("%s-lib.c", item.name));
    String library = emit_lib_artifact(source, generated)!;
    char[] host = read_file("tests/host/numeric64_fault_host.c", artifact_source_buf[..])!;
    DString driver = dstring::temp();
    driver.appendf("#define NUMERIC64_EXPECTED_CODE %s\n", item.code);
    driver.appendf("#define NUMERIC64_EXPECTED_LINE %d\n", item.line);
    if (item.cell.len > 0) {
        driver.appendf("#define NUMERIC64_DATA_CELL %s\n", item.cell);
    }
    if (item.out_cell.len > 0) {
        driver.appendf("#define NUMERIC64_OUT_CELL %s\n", item.out_cell);
    }
    if (item.guard_offset > 0) {
        driver.appendf("#define NUMERIC64_GUARD_OFFSET %d\n", item.guard_offset);
    }
    driver.append_string(library);
    driver.append_string((String)host);
    String driver_path = temp_path(string::tformat("%s-driver.c", item.name));
    String executable = temp_path(string::tformat("%s-driver.exe", item.name));
    write_file(driver_path, driver.str_view())!;
    ProcessResult compiled = compile_c(driver_path, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "numeric64 ABI fault compilation")) {
        io::eprintn(item.name);
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    if (!expect(runtime.status == 0 && runtime.stdout_text.len == 0 &&
            runtime.stderr_text.len == 0, "numeric64 ABI fault result or canary")) {
        io::eprintn(item.name);
        print_result(runtime);
        return 1;
    }
    return 0;
}

fn int? check_numeric64_fault_abi() {
    Numeric64FaultCase[] cases = {
        { .name = "numeric64_cadd_i64_overflow", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 2 },
        { .name = "numeric64_cinc_i64_overflow", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 2 },
        { .name = "numeric64_cdec_u64_underflow", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 2 },
        { .name = "numeric64_div_i64_min_minus_one", .code = "RZA_FAULT_DIVISION",
            .line = 2 },
        { .name = "numeric64_div_u64_zero", .code = "RZA_FAULT_DIVISION", .line = 3 },
        { .name = "numeric64_shift_i64_negative", .code = "RZA_FAULT_SHIFT", .line = 2 },
        { .name = "numeric64_shift_u64_sixty_four", .code = "RZA_FAULT_SHIFT", .line = 2 },
        { .name = "numeric64_checked_index_attack", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 4, .cell = "c_data" },
        { .name = "numeric64_checked_index_proc", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 5, .cell = "c_data" },
        { .name = "numeric64_checked_index_sync", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 5, .cell = "c_data" },
        { .name = "numeric64_checked_index_async", .code = "RZA_FAULT_OUT_OF_BOUNDS",
            .line = 5, .cell = "c_data", .out_cell = "c_out", .guard_offset = 8 },
        { .name = "numeric64_async_overflow", .code = "RZA_FAULT_ARITHMETIC_OVERFLOW",
            .line = 5, .cell = "c_result", .out_cell = "c_async_out" },
    };
    int failures = 0;
    foreach (item : cases) {
        if (check_numeric64_fault_case(item)! != 0) failures++;
    }
    if (!expect(failures == 0, "numeric64 ABI fault cases")) return 1;
    io::printn("NUMERIC64_ABI_FAULTS OK (12 programs)");
    return 0;
}


const String FLOAT_MEMORY_SOURCE = "res data, field, 32\n"
    "med data_m, data, field\nproc canonical(data_m: rw):\n"
    "    mov %r0, -1\n    mov.f32 %r1, %r0\n    store [data_m + 0], %r1\n"
    "    mov.f32 %r2, 0x3f800000\n    store.f32 [data_m + 8], %r2\n"
    "    mov.f64 %r3, 0x3ff0000000000000\n    store.f64 [data_m + 16], %r3\n"
    "    ret\n";

const String FLOAT_MEMORY_HOST = "\nstatic int float_memory_fail(const char *name) {\n"
    "    printf(\"%s\\r\\n\", name);\n    return 1;\n}\n\n"
    "int main(void) {\n"
    "    RzaResult result = rza_boot();\n"
    "    if (result.code != RZA_OK) return float_memory_fail(\"BOOT\");\n"
    "    unsigned char *data = rza_deref_cell(rza_med_data_m());\n"
    "    if (data == NULL) return float_memory_fail(\"DATA\");\n"
    "    memset(data, 0x5a, 32);\n"
    "    result = rza_canonical();\n"
    "    if (result.code != RZA_OK) return float_memory_fail(\"CALL\");\n"
    "    uint64_t container;\n"
    "    memcpy(&container, data, sizeof(container));\n"
    "    if (container != UINT64_C(0x00000000ffffffff)) {\n"
    "        return float_memory_fail(\"F32_UPPER\");\n"
    "    }\n"
    "    uint32_t single;\n"
    "    memcpy(&single, data + 8, sizeof(single));\n"
    "    if (single != UINT32_C(0x3f800000)) return float_memory_fail(\"F32_BITS\");\n"
    "    if (data[12] != 0x5a) return float_memory_fail(\"F32_CANARY\");\n"
    "    uint64_t word;\n"
    "    memcpy(&word, data + 16, sizeof(word));\n"
    "    if (word != UINT64_C(0x3ff0000000000000)) {\n"
    "        return float_memory_fail(\"F64_BITS\");\n"
    "    }\n"
    "    if (data[24] != 0x5a) return float_memory_fail(\"F64_CANARY\");\n"
    "    return 0;\n}\n";

fn String float_artifact_replace(String text, String needle, String replacement, bool* changed) {
    DString out = dstring::temp();
    sz? found = text.index_of(needle);
    if (catch found) {
        *changed = false;
        return text;
    }
    out.append_string(text[:found]);
    out.append_string(replacement);
    out.append_string(text[found + needle.len..]);
    *changed = true;
    return out.str_view();
}

fn int? run_float_memory_driver(String library, String name, String expected) {
    DString driver = dstring::temp(library);
    driver.append_string(FLOAT_MEMORY_HOST);
    String source = temp_path(string::tformat("%s.c", name));
    String executable = temp_path(string::tformat("%s.exe", name));
    write_file(source, driver.str_view())!;
    ProcessResult compiled = compile_c(source, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "float memory driver compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    bool clean = expected.len == 0;
    bool valid = clean ? runtime.status == 0 && runtime.stdout_text.len == 0
        : runtime.status == 1 && normalize_lines(runtime.stdout_text) == normalize_lines(expected);
    if (!expect(valid && runtime.stderr_text.len == 0, "float memory observation")) {
        io::eprintn(name);
        print_result(runtime);
        return 1;
    }
    return 0;
}

fn int? check_float_memory_mutation(String library, String name, String before,
        String after, String expected) {
    bool changed;
    String mutated = float_artifact_replace(library, before, after, &changed);
    if (!expect(changed, "float memory mutation anchor")) return 1;
    return run_float_memory_driver(mutated, name, expected);
}

fn int? check_float_memory_artifact() {
    String source = temp_path("float-memory.rza");
    write_file(source, FLOAT_MEMORY_SOURCE)!;
    String library = emit_lib_artifact(source, temp_path("float-memory.c"))!;
    if (run_float_memory_driver(library, "float-memory-clean", "")! != 0) return 1;
    if (check_float_memory_mutation(library, "float-memory-upper",
            "r1 = rez_f32_from_bits((uint64_t)r0);", "r1 = r0;",
            "F32_UPPER\n")! != 0) return 1;
    String f32_before = "{ uint32_t value = (uint32_t)rez_i64_bits(r2);\n"
        "        memcpy((char*)p_data_m + 8, &value, 4);";
    String f32_after = "{ uint64_t value[2] = { rez_i64_bits(r2), 0 };\n"
        "        memcpy((char*)p_data_m + 8, &value, 8);";
    if (check_float_memory_mutation(library, "float-memory-wide32", f32_before,
            f32_after, "F32_CANARY\n")! != 0) return 1;
    String f64_before = "{ uint64_t value = (uint64_t)rez_i64_bits(r3);\n"
        "        memcpy((char*)p_data_m + 16, &value, 8);";
    String f64_after = "{ uint64_t value[2] = { rez_i64_bits(r3), 0 };\n"
        "        memcpy((char*)p_data_m + 16, &value, 16);";
    if (check_float_memory_mutation(library, "float-memory-wide64", f64_before,
            f64_after, "F64_CANARY\n")! != 0) return 1;
    io::printn("FLOAT_MEMORY_ABI OK (4 programs)");
    return 0;
}


struct FloatFaultCase {
    String name;
    String source;
    int line;
    String data_cell;
    uint data_size;
    ulong data_expected;
    int callback_offset;
    String out_cell;
    String out_mediator;
}

fn int? run_float_fault_driver(FloatFaultCase item, String library,
        String header, String variant, bool clean) {
    String directory = temp_path(string::tformat("%s-%s", item.name, variant));
    path::mkdir(path::tnew(directory)!, true)!;
    DString driver = dstring::temp();
    driver.appendf("#define FLOAT_EXPECTED_CODE RZA_FAULT_ARITHMETIC_OVERFLOW\n");
    driver.appendf("#define FLOAT_EXPECTED_LINE %d\n", item.line);
    if (item.data_cell.len > 0) {
        driver.appendf("#define FLOAT_DATA_CELL %s\n", item.data_cell);
        driver.appendf("#define FLOAT_DATA_SIZE %d\n", item.data_size);
        driver.appendf("#define FLOAT_DATA_EXPECTED UINT64_C(0x%016x)\n", item.data_expected);
    }
    if (item.callback_offset > 0) {
        driver.appendf("#define FLOAT_CALLBACK_OFFSET %d\n", item.callback_offset);
    }
    if (item.out_cell.len > 0) driver.appendf("#define FLOAT_OUT_CELL %s\n", item.out_cell);
    if (item.out_mediator.len > 0) {
        driver.appendf("#define FLOAT_OUT_MEDIATOR %s\n", item.out_mediator);
    }
    driver.append_string(library);
    char[] host = read_file("tests/host/float_fault_host.c", artifact_source_buf[..])!;
    driver.append_string((String)host);
    String source = string::tformat("%s/driver.c", directory);
    String executable = string::tformat("%s/driver.exe", directory);
    write_file(source, driver.str_view())!;
    if (header.len > 0) {
        write_file(string::tformat("%s/rez3ext.h", directory), header)!;
    }
    ProcessResult compiled = compile_c(source, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "float fault driver compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    bool valid = clean ? runtime.status == 0 && runtime.stdout_text.len == 0 &&
        runtime.stderr_text.len == 0 : runtime.status != 0;
    if (!expect(valid, clean ? "float fault clean driver" : "float fault mutation mismatch")) {
        io::eprintn(item.name);
        print_result(runtime);
        return 1;
    }
    return 0;
}

fn int? check_float_fault_case(FloatFaultCase item) {
    String library = emit_lib_artifact(item.source,
        temp_path(string::tformat("%s.c", item.name)))!;
    if (run_float_fault_driver(item, library, "", "clean", true)! != 0) return 1;
    return 0;
}

fn int? check_float_fault_mutation(FloatFaultCase item, String header_before,
        String header_after, String guard_before, String guard_after, String variant) {
    String library = emit_lib_artifact(item.source,
        temp_path(string::tformat("%s-mutant.c", item.name)))!;
    String header = "";
    if (header_before.len > 0) {
        char[] original = read_file("include/rza/rez3ext.h", artifact_source_buf[..])!;
        bool changed;
        header = float_artifact_replace(normalize_lines((String)original),
            header_before, header_after, &changed);
        if (!expect(changed, "float fault header mutation anchor")) return 1;
    }
    if (guard_before.len > 0) {
        bool changed;
        library = float_artifact_replace(library, guard_before, guard_after, &changed);
        if (!expect(changed, "float fault guard mutation anchor")) return 1;
    }
    return run_float_fault_driver(item, library, header, variant, false);
}

fn int? check_float_fault_artifacts() {
    FloatFaultCase invalid = {
        .name = "float-cvt-invalid", .source = "tests/fixtures/core/float_cvt_invalid.rza",
        .line = 5, .data_cell = "c_data", .data_size = 16, .callback_offset = 4,
    };
    FloatFaultCase asynchronous = {
        .name = "float-cvt-async", .source = "tests/fixtures/async/float_cvt_async_overflow.rza",
        .line = 7, .data_cell = "c_data", .data_size = 8,
        .data_expected = 0x7f800000, .out_cell = "c_out", .out_mediator = "rza_med_out_m",
    };
    if (check_float_fault_case(invalid)! != 0) return 1;
    if (check_float_fault_case(asynchronous)! != 0) return 1;
    String lower_path = temp_path("float-cvt-lower.rza");
    write_file(lower_path, "mov.f32 %r0, 0xc3010000\ncvt.i8.f32 %r1, %r0\nret\n")!;
    FloatFaultCase lower = { .name = "float-cvt-lower", .source = lower_path, .line = 2 };
    if (check_float_fault_case(lower)! != 0) return 1;
    String upper_path = temp_path("float-cvt-upper.rza");
    write_file(upper_path, "mov.f32 %r0, 0x5f800000\ncvt.u64.f32 %r1, %r0\nret\n")!;
    FloatFaultCase upper = { .name = "float-cvt-upper", .source = upper_path, .line = 2 };
    if (check_float_fault_case(upper)! != 0) return 1;
    String[] names = { "float-cvt-next32", "float-cvt-next64", "float-cvt-next64-f64" };
    String[] sources = {
        "mov.f32 %r0, 0xcf000001\ncvt.i32.f32 %r1, %r0\nret\n",
        "mov.f32 %r0, 0xdf000001\ncvt.i64.f32 %r1, %r0\nret\n",
        "mov.f64 %r0, 0xc3e0000000000001\ncvt.i64.f64 %r1, %r0\nret\n",
    };
    for (usz i = 0; i < names.len; i++) {
        String source = temp_path(string::tformat("%s.rza", names[i]));
        write_file(source, sources[i])!;
        FloatFaultCase item = { .name = names[i], .source = source, .line = 2 };
        if (check_float_fault_case(item)! != 0) return 1;
    }
    return 0;
}

fn int? check_float_fault_mutations() {
    FloatFaultCase invalid = {
        .name = "float-cvt-invalid", .source = "tests/fixtures/core/float_cvt_invalid.rza",
        .line = 5, .data_cell = "c_data", .data_size = 16, .callback_offset = 4,
    };
    String finite_before = "static bool rez_f32_to_i32(int64_t container, int64_t *out) {\n"
        "    assert(out != NULL);\n    if (!rez_f32_finite(container)) return true;";
    String finite_after = "static bool rez_f32_to_i32(int64_t container, int64_t *out) {\n"
        "    assert(out != NULL);\n    if (false) return true;";
    if (check_float_fault_mutation(invalid, finite_before, finite_after, "", "",
            "finite")! != 0) return 1;
    FloatFaultCase lower = {
        .name = "float-cvt-lower", .source = temp_path("float-cvt-lower.rza"), .line = 2,
    };
    if (check_float_fault_mutation(lower, "value <= -129.0f", "value < -129.0f",
            "", "", "lower")! != 0) return 1;
    FloatFaultCase upper = {
        .name = "float-cvt-upper", .source = temp_path("float-cvt-upper.rza"), .line = 2,
    };
    if (check_float_fault_mutation(upper, "value >= 0x1p64f", "value > 0x1p64f",
            "", "", "upper")! != 0) return 1;
    if (check_float_fault_mutation(invalid, "", "", "if (rez_f32_to_i32(",
            "if (false && rez_f32_to_i32(", "guard")! != 0) return 1;
    io::printn("FLOAT_CONVERSION_FAULTS OK (11 programs)");
    return 0;
}


fn int? run_float_rhs_program(String generated, String name, String expected,
        bool require_match) {
    String executable = temp_path(string::tformat("%s.exe", name));
    ProcessResult compiled = compile_c(generated, executable)!;
    if (!expect(compiled.status == 0 && compiled.stderr_text.len == 0,
            "float RHS mutation compilation")) {
        print_result(compiled);
        return 1;
    }
    ProcessResult runtime = run_simple({ executable })!;
    bool output_ok = require_match ? runtime.stdout_text == expected
        : runtime.stdout_text != expected;
    if (!expect(runtime.status == 0 && runtime.stderr_text.len == 0 && output_ok,
            "float RHS mutation observation")) {
        print_result(runtime);
        return 1;
    }
    return 0;
}

fn int? check_float_rhs_mutation(String source_text, String name) {
    String source = temp_path(string::tformat("%s.rza", name));
    write_file(source, source_text)!;
    String generated_path = temp_path(string::tformat("%s.c", name));
    String generated = emit_artifact(source, generated_path)!;
    if (run_float_rhs_program(generated_path, string::tformat("%s-clean", name),
            "1077936128\n", true)! != 0) return 1;
    bool changed;
    String mutated = float_artifact_replace(generated, "rez_f32_add", "rez_f32_sub", &changed);
    if (!expect(changed, "float RHS mutation anchor")) return 1;
    String mutant_path = temp_path(string::tformat("%s-mutant.c", name));
    write_file(mutant_path, mutated)!;
    return run_float_rhs_program(mutant_path, string::tformat("%s-mutant", name),
        "1077936128\n", false);
}

fn int? check_float_rhs_mutations() {
    if (check_float_rhs_mutation("mov.f32 %r0, 0x3f800000\n"
            "add.f32 %r2, %r0, 0x40000000\nprint %r2\nret\n",
            "float-rhs-immediate")! != 0) return 1;
    if (check_float_rhs_mutation("mov.f32 %r0, 0x3f800000\n"
            "mov.f32 %r1, 0x40000000\nadd.f32 %r2, %r0, %r1\nprint %r2\nret\n",
            "float-rhs-register")! != 0) return 1;
    io::printn("FLOAT_RHS_MUTATIONS OK (4 programs)");
    return 0;
}


fn int? check_float_profile_artifact() {
    String legacy = emit_artifact("tests/fixtures/core/mov_self.rza",
        temp_path("legacy-without-float.c"))!;
    if (!expect(!legacy.contains("#include <float.h>") &&
            !legacy.contains("FLT_EVAL_METHOD") && !legacy.contains("fp reassociate"),
            "legacy generated C must not acquire strict FP guards")) return 1;
    String unaligned = emit_artifact("tests/fixtures/core/float_unaligned.rza",
        temp_path("float-exact-access.c"))!;
    if (!expect(unaligned.contains("#include <float.h>") &&
            unaligned.contains("#pragma GCC optimize (\"fp-contract=off\")") &&
            unaligned.contains("memcpy((char*)p + 1, &value, 4)") &&
            unaligned.contains("memcpy((char*)p + 9, &value, 8)"),
            "float strict profile or exact-width access")) return 1;
    String conversion = emit_artifact("tests/fixtures/core/float_cvt_invalid.rza",
        temp_path("float-conversion-guard.c"))!;
    if (!expect(conversion.contains("if (rez_f32_to_i32(r0, &r1))") &&
            conversion.contains("\"invalid conversion\""),
            "float conversion guard artifact")) return 1;
    io::printn("FLOAT_ARTIFACT_PROFILE OK");
    return 0;
}
