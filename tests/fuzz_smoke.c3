module rza_tests;

import std::core::dstring;
import std::io;
import std::io::file;

const String FUZZ_SEED = "cav main, field\n"
    "res x, main, 16\n"
    "med x_m, x, main\n"
    "mov %r0, 42\n"
    "store [x_m + 0], %r0\n"
    "load %r1, [x_m + 0]\n"
    "print %r1\n"
    "decay main\n"
    "ret\n";

const String LAYOUT_FUZZ_SEED = "layout Entry: key:i64, value:i64\n"
    "res x, field, Entry[2]\nmed x_m, x, field\n"
    "mov %r0, 42\nmov %r1, 1\nstore [x_m + %r1].value, %r0\n"
    "load %r2, [x_m + 0].key\nprint %r2\nret\n";

struct Rng {
    ulong state;
}

fn ulong Rng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn int Rng.below(&self, int limit) {
    return (int)(self.next() % (ulong)limit);
}

fn int? check_fuzz(String text, bool emit, String diagnostic,
        bool expect_success, long max_output) {
    String path = temp_path("case.rza");
    write_file(path, text)!;
    String generated = temp_path("case.c");
    String[] check = { compiler_path(), path };
    String[] emit_cmd = { compiler_path(), path, "--emit-c", "-o", generated };
    ProcessResult result = run_simple(emit ? emit_cmd : check)!;
    if (expect_success) {
        if (!expect(result.status == 0, "fuzz emit failed")) {
            print_result(result);
            return 1;
        }
        if (max_output > 0) {
            long size = file::get_size(generated)!;
            if (!expect(size <= max_output, "fuzz generated output exceeds bound")) return 1;
        }
        return 0;
    }
    if (diagnostic.len > 0) {
        if (!expect(result.status == 1 && result.stderr_text.contains(diagnostic),
                "fuzz diagnostic mismatch")) return 1;
        return 0;
    }
    if (!expect(result.status == 0 || result.status == 1, "fuzz exit outside 0/1")) {
        return 1;
    }
    return 0;
}

fn int? run_mutations(Rng* rng) {
    String alphabet = "[]%,:+-x09.\n";
    String[] seeds = { FUZZ_SEED, LAYOUT_FUZZ_SEED };
    foreach (seed : seeds) {
        for (int case_index = 0; case_index < 80; case_index++) {
            DString text = dstring::temp(seed);
            int changes = rng.below(7) + 1;
            for (int i = 0; i < changes; i++) {
                sz pos = (sz)rng.below((int)text.len() + 1);
                if (rng.below(2) == 1) {
                    String current = text.str_view();
                    DString changed = dstring::temp(current[:pos]);
                    changed.append_char(alphabet[rng.below((int)alphabet.len)]);
                    changed.append(current[pos..]);
                    text = changed;
                } else if (text.len() > 0 && pos < text.len()) {
                    text.delete(pos);
                }
            }
            if (check_fuzz(text.str_view(), false, "", false, 0)! != 0) return 1;
        }
    }
    return 0;
}

fn int? run_token_cases(Rng* rng) {
    String[] tokens = {
        "cav main, field", "res x, main, 16", "med x_m, x, main",
        "load %r0, [x_m + 0]", "store [x_m + 0], %r0", "print %r0",
        "proc worker:", "casc c: x_m -> out[field]", "acasc c: x_m -> out",
        "endc", "ret", "decay main", "jmp nowhere", "label:", "mov %r0, 1",
        "add %r1, %r0, 2", "loadb %r0, [x_m + 1]", "raise x, field",
        "cav", "", "; comment", "out[field]junk", "%r99", "2147483648",
        "layout Entry: key:i64, value:i64", "res entries, field, Entry[2]",
        "load %r0, [entries_m + 0].key", "store [entries_m + %r1].value, %r0",
        "layout Entry: key:u32", "Entry[0]",
    };
    for (int case_index = 0; case_index < 80; case_index++) {
        DString text = dstring::temp();
        int lines = rng.below(39) + 1;
        for (int i = 0; i < lines; i++) {
            text.append(tokens[rng.below((int)tokens.len)]);
            text.append("\n");
        }
        if (check_fuzz(text.str_view(), false, "", false, 0)! != 0) return 1;
    }
    return 0;
}

fn String deep_source(bool reverse) {
    DString text = dstring::temp("cav f0, field\n");
    for (int i = 1; i < 4000; i++) text.appendf("cav f%d, f%d\n", i, i - 1);
    if (reverse) {
        for (int i = 3999; i >= 0; i--) text.appendf("decay f%d\n", i);
    } else {
        text.append("decay f0\n");
    }
    text.append("ret\n");
    return text.str_view();
}

fn int? run_capacity_cases() {
    if (check_fuzz(deep_source(false), true, "", true, 0)! != 0) return 1;
    if (check_fuzz(deep_source(true), true, "", true, 4000 * 512)! != 0) return 1;
    DString huge = dstring::temp();
    huge.append_char_repeat(';', 1048577);
    if (check_fuzz(huge.str_view(), false, "source exceeds 1048576 bytes",
            false, 0)! != 0) return 1;
    DString instructions = dstring::temp();
    for (int i = 0; i < 16385; i++) instructions.append("mov %r0, 1\n");
    if (check_fuzz(instructions.str_view(), false, "too many instructions",
            false, 0)! != 0) return 1;
    DString cascade = dstring::temp("cav m, field\nres x, m, 8\n"
        "med x_m, x, m\ncasc c: x_m -> out[m]\n");
    for (int i = 0; i < 16380; i++) cascade.append("mov %r0, 1\n");
    cascade.append("endc\n");
    if (check_fuzz(cascade.str_view(), false, "too many instructions",
            false, 0)! != 0) return 1;
    return 0;
}

fn int fuzz_main() {
    defer (void)cleanup_temp_dir();
    int? status = fuzz_run();
    if (catch status) {
        io::eprintn("FUZZ FAILED");
        return 1;
    }
    return status;
}

fn int? fuzz_run() {
    reset_temp_dir()!;
    Rng rng = { 0x5EED };
    if (run_mutations(&rng)! != 0) return 1;
    if (run_token_cases(&rng)! != 0) return 1;
    if (run_capacity_cases()! != 0) return 1;
    io::printn("FUZZ OK (245 cases)");
    return 0;
}
