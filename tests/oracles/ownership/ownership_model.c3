module rza_tests;

import std::core::dstring;

struct OwnershipCase {
    String source;
    String stdout_text;
    String stderr_text;
    int status;
    bool static_error;
}

struct OwnModel {
    DString source;
    DString expected;
    int tmp_value;
    int tick_value;
    int calls;
    int global_value;
    bool raised;
    bool has_global;
}

struct OwnRng {
    ulong state;
}

fn ulong OwnRng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn int OwnRng.below(&self, int limit) {
    return (int)(self.next() % (ulong)limit);
}

fn void own_probe(OwnModel* model, String med, bool alive) {
    model.source.appendf("probe %s\n", med);
    model.expected.append(alive ? "ALIVE\n" : "DEAD\n");
}

fn void own_checked_noop(OwnModel* model, int reg) {
    model.source.appendf("    cadd %%r%d, %%r%d, 0\n", reg, reg);
    model.source.appendf("    csub %%r%d, %%r%d, 0\n", reg, reg);
    model.source.appendf("    cmul %%r%d, %%r%d, 1\n", reg, reg);
    model.source.appendf("    cinc %%r%d\n    cdec %%r%d\n", reg, reg);
}

fn void own_proc(OwnModel* model, int seed) {
    model.tick_value = 20 + seed % 10;
    model.source.append("proc tick:\n"
        "    res tick_cell, tick, 8\n"
        "    med tick_m, tick_cell, tick\n");
    model.source.appendf("    mov %%r0, %d\n", model.tick_value);
    model.source.append("    store [tick_m + 0], %r0\n"
        "    load %r0, [tick_m + 0]\n"
        "    print %r0\n"
        "    load %r0, [counter_m + 0]\n");
    own_checked_noop(model, 0);
    model.source.append("    inc %r0\n"
        "    store [counter_m + 0], %r0\n"
        "ret\n");
}

fn void own_global(OwnModel* model) {
    model.source.append("res global, field, 8\n"
        "med global_m, global, field\n");
    model.source.appendf("mov %%r0, %d\nstore [global_m + 0], %%r0\n",
        model.global_value);
    model.source.append("acasc bump: global_m -> gout\n"
        "    load %r0, [global_m + 0]\n");
    own_checked_noop(model, 0);
    model.source.append("    inc %r0\n"
        "    store [global_m + 0], %r0\n"
        "endc\n"
        "await %r0\n"
        "load %r0, [global_m + 0]\n"
        "print %r0\n");
    model.expected.appendf("%d\n", model.global_value + 1);
}

fn OwnershipCase own_valid(int seed) {
    OwnRng rng = { (ulong)seed };
    OwnModel model;
    model.source = dstring::temp();
    model.expected = dstring::temp();
    model.tmp_value = rng.below(49) + 1;
    bool typed = seed % 2 == 0;
    if (typed) model.source.append("layout Value: value:i64\n");
    model.source.append("cav main, field\n"
        "res counter, main, 8\n"
        "med counter_m, counter, main\n"
        "cav child, main\n");
    model.source.append(typed ? "res tmp, child, Value\n" : "res tmp, child, 8\n");
    model.source.append("med tmp_m, tmp, child\n");
    model.source.appendf("mov %%r0, %d\n", model.tmp_value);
    model.source.appendf("store [tmp_m + 0]%s, %%r0\n", typed ? ".value" : "");
    model.raised = rng.below(2) == 1;
    if (model.raised) {
        model.source.append("raise tmp, main\nmed lifted_m, tmp, main\n");
    }
    String lifted = model.raised ? "lifted_m" : "tmp_m";
    model.source.appendf("casc addup: counter_m,%s -> sum[main]\n", lifted);
    model.source.append("    load %r0, [counter_m + 0]\n");
    model.source.appendf("    load %%r1, [%s + 0]%s\n", lifted,
        typed ? ".value" : "");
    model.source.append("    add %r2, %r0, %r1\n");
    own_checked_noop(&model, 2);
    model.source.append("    store [counter_m + 0], %r2\n"
        "endc\n");
    own_probe(&model, "tmp_m", true);
    own_probe(&model, lifted, true);
    own_proc(&model, seed);
    model.calls = rng.below(3) + 1;
    for (int i = 0; i < model.calls; i++) {
        model.source.append("call tick\n");
        model.expected.appendf("%d\n", model.tick_value);
    }
    model.has_global = rng.below(2) == 1;
    if (model.has_global) {
        model.global_value = rng.below(9) + 1;
        own_global(&model);
    }
    model.source.append("decay child\n");
    own_probe(&model, "tmp_m", false);
    own_probe(&model, lifted, false);
    model.source.append("load %r0, [counter_m + 0]\nprint %r0\n"
        "decay main\nret\n");
    model.expected.appendf("%d\n", model.tmp_value + model.calls);
    return { model.source.str_view(), model.expected.str_view(), "", 0, false };
}

fn String own_common() {
    DString out = dstring::temp("cav main, field\n"
        "res counter, main, 8\n"
        "med counter_m, counter, main\n"
        "cav child, main\n"
        "res tmp, child, 8\n"
        "med tmp_m, tmp, child\n"
        "mov %r0, 7\n"
        "store [tmp_m + 0], %r0\n");
    return out.str_view();
}

fn OwnershipCase own_abort() {
    String source = "cav main, field\nres tmp, main, 8\nmed tmp_m, tmp, main\n"
        "mov %r1, 2\nloop:\ncasc aborted: tmp_m -> out[main]\n"
        "    load %r0, [tmp_m + 0]\n    inc %r0\n"
        "    store [tmp_m + 0], %r0\nendc\ndecay main\n"
        "dec %r1\nbrnz %r1, loop\nprint %r1\nret\n";
    String diagnostic = "ABORT line 6: cascade aborted: dead mediator tmp_m";
    return { source, "0", diagnostic, 0, false };
}

fn OwnershipCase own_invalid(String rule) {
    if (rule == "ABORT") return own_abort();
    DString out = dstring::temp(own_common());
    String diagnostic = "";
    if (rule == "I2") {
        out.append("cav other, main\nmed bad_m, tmp, other\n");
        diagnostic = "VIOLATION line 10 [I2]: link issued by non-owner non-ancestor other tmp";
    } else if (rule == "I1") {
        out.append("decay child\nres late, child, 8\n");
        diagnostic = "VIOLATION line 10 [I1]: cell in dead frame late child";
    } else if (rule == "I3") {
        out.append("decay child\ncasc bad: tmp_m -> out[main]\nendc\n");
        diagnostic = "VIOLATION line 10 [I3]: sync cascade aborted: dead link on entry bad tmp_m";
    } else if (rule == "I4") {
        out.append("decay child\nraise tmp, field\n");
        diagnostic = "VIOLATION line 10 [I4]: raise of cell in dead frame tmp child";
    } else if (rule == "DECAY") {
        out.append("decay child\ndecay child\n");
        diagnostic = "VIOLATION line 10 [DECAY]: double leave child";
    } else if (rule == "DUP") {
        out.append("res tmp, child, 8\n");
        diagnostic = "VIOLATION line 9 [DUP]: duplicate name tmp";
    } else if (rule == "STRUCT") {
        out.append("casc bad: tmp_m -> out\nendc\n");
        diagnostic = "VIOLATION line 9 [STRUCT]: sync cascade out frame is required\n"
            "VIOLATION line 10 [STRUCT]: endc without casc";
    } else if (rule == "SCOPE") {
        out.append("proc p:\n    res x, p, 8\nret\nmed x_m, x, field\n"
            "proc q:\n    load %r0, [x_m + 0]\nret\ncall q\n");
        diagnostic = "VIOLATION line 14 [SCOPE]: mediator x_m is not visible from procedure body "
            "(only proc-locals and field-owned mediators are)";
    } else if (rule == "FAULT") {
        out.append("decay child\nload %r0, [tmp_m + 0]\n");
        diagnostic = "FAULT line 10: dead mediator tmp_m";
    }
    out.append("decay main\nret\n");
    if (rule == "FAULT") return { out.str_view(), "", diagnostic, 1, false };
    return { out.str_view(), "", diagnostic, 1, true };
}
