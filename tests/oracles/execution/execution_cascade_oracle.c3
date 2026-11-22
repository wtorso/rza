module rza_tests;

import std::core::dstring;
import std::io;

const int CASC_SITES_MAX = 65;
const int CASC_CELLS_MAX = CASC_SITES_MAX + 2;
const int CASC_OPS_MAX = 512;
const int CASC_BODY_MAX = 32;
const int CASC_SCENARIO_COUNT = 10;

enum CascScenario : char {
    SYNC_SUCCESS,
    SYNC_ABORT,
    ASYNC_FIFO,
    PENDING_OUT,
    ASYNC_ABORT,
    REPEAT_PENDING,
    QUEUE_FULL,
    ASYNC_BODY_FAULT,
    ASYNC_CANCEL,
    ASYNC_REENQUEUE,
}

enum CascOpcode : char {
    MOV_IMM,
    LOAD,
    STORE,
    PRINT,
    PROBE,
    INC,
    DEC,
    ADD,
    CADD,
    LABEL,
    BRNZ,
    AWAIT,
    DECAY_MAIN,
    MED_OUT,
    CASC,
    RET,
}

struct CascOp {
    CascOpcode code;
    int dst;
    int left;
    int cell;
    int site;
    int target;
    int line;
    long literal;
    bool snapshot_probe;
    bool caller_probe;
}

struct CascSite {
    CascOp[CASC_BODY_MAX] body;
    int body_len;
    int input;
    int out;
    int line;
    bool is_async;
}

struct CascCell {
    long value;
    bool home_main;
    bool async_out;
    bool published;
}

struct CascProgram {
    CascOp[CASC_OPS_MAX] ops;
    int len;
    CascSite[CASC_SITES_MAX] sites;
    int site_count;
    CascCell[CASC_CELLS_MAX] cells;
    bool sync_home;
}

struct CascBuilder {
    CascProgram program;
    DString source;
    int line;
}

CascBuilder cascade_builder_storage;

fn OracleWorld cascade_oracle_world(ulong seed) {
    OracleRng config = { seed ^ 0x94d049bb133111eb };
    CascScenario scenario = (CascScenario)(int)((seed - 1) % CASC_SCENARIO_COUNT);
    int tasks = 1;
    if (scenario == CascScenario.ASYNC_FIFO) tasks = 2;
    if (scenario == CascScenario.QUEUE_FULL) tasks = CASC_SITES_MAX;
    return {
        .seed = seed,
        .prefix_ops = 1 + config.below(3),
        .loop_trips = 2,
        .cascade_scenario = scenario,
        .cascade_tasks = tasks,
    };
}

fn String casc_cell_name(int cell) {
    if (cell == 0) return "x";
    if (cell == 1) return "y";
    return string::tformat("out%d", cell - 2);
}

fn String casc_med_name(int cell) {
    return string::tformat("%s_m", casc_cell_name(cell));
}

fn CascBuilder* casc_builder(bool sync_home) {
    CascBuilder* builder = &cascade_builder_storage;
    *builder = {
        .program = { .sync_home = sync_home },
        .source = dstring::temp(),
        .line = 1,
    };
    builder.program.cells[0].published = true;
    builder.program.cells[1].published = true;
    builder.program.cells[0].home_main = sync_home;
    if (sync_home) builder.source.append("cav main, field\n");
    builder.source.appendf("res x, %s, 8\n", sync_home ? "main" : "field");
    builder.source.appendf("med x_m, x, %s\n", sync_home ? "main" : "field");
    builder.source.append("res y, field, 8\nmed y_m, y, field\n");
    builder.line = sync_home ? 6 : 5;
    return builder;
}

fn void casc_push(CascBuilder* builder, CascOp op) {
    assert(builder.program.len >= 0 && builder.program.len < CASC_OPS_MAX);
    builder.program.ops[builder.program.len] = op;
    builder.program.len++;
}

fn void casc_write(CascBuilder* builder, CascOp* op, bool body) {
    if (body) builder.source.append("    ");
    switch (op.code) {
        case CascOpcode.MOV_IMM:
            builder.source.appendf("mov %%r%d, %d\n", op.dst, op.literal);
        case CascOpcode.LOAD:
            builder.source.appendf("load %%r%d, [%s + 0]\n", op.dst,
                casc_med_name(op.cell));
        case CascOpcode.STORE:
            builder.source.appendf("store [%s + 0], %%r%d\n",
                casc_med_name(op.cell), op.left);
        case CascOpcode.PRINT: builder.source.appendf("print %%r%d\n", op.left);
        case CascOpcode.PROBE: builder.source.appendf("probe %s\n", casc_med_name(op.cell));
        case CascOpcode.INC: builder.source.appendf("inc %%r%d\n", op.dst);
        case CascOpcode.DEC: builder.source.appendf("dec %%r%d\n", op.dst);
        case CascOpcode.ADD:
            builder.source.appendf("add %%r%d, %%r%d, %d\n", op.dst, op.left, op.literal);
        case CascOpcode.CADD:
            builder.source.appendf("cadd %%r%d, %%r%d, %d\n", op.dst, op.left, op.literal);
        case CascOpcode.LABEL: builder.source.appendf("l%d:\n", op.literal);
        case CascOpcode.BRNZ:
            builder.source.appendf("brnz %%r%d, l%d\n", op.left, op.target);
        case CascOpcode.AWAIT: builder.source.appendf("await %%r%d\n", op.dst);
        case CascOpcode.DECAY_MAIN: builder.source.append("decay main\n");
        case CascOpcode.MED_OUT:
            builder.source.appendf("med %s, %s, field\n",
                casc_med_name(op.cell), casc_cell_name(op.cell));
        case CascOpcode.RET: builder.source.append("ret\n");
        case CascOpcode.CASC: unreachable();
    }
}

fn void casc_emit(CascBuilder* builder, CascOp op) {
    op.line = builder.line;
    casc_push(builder, op);
    casc_write(builder, &builder.program.ops[builder.program.len - 1], false);
    builder.line++;
}

fn int casc_start(CascBuilder* builder, int input, bool is_async) {
    assert(builder.program.site_count >= 0 && builder.program.site_count < CASC_SITES_MAX);
    int index = builder.program.site_count;
    int out = index + 2;
    CascSite site = {
        .input = input, .out = out, .line = builder.line, .is_async = is_async,
    };
    builder.program.sites[index] = site;
    builder.program.site_count++;
    builder.program.cells[out].async_out = is_async;
    builder.program.cells[out].home_main = !is_async && builder.program.sync_home;
    String kind = is_async ? "acasc" : "casc";
    String name = is_async ? "a" : "c";
    builder.source.appendf("%s %s%d: %s -> out%d", kind, name, index,
        casc_med_name(input), index);
    if (is_async) {
        builder.source.append("\n");
    } else {
        builder.source.appendf("[%s]\n", builder.program.sync_home ? "main" : "field");
    }
    casc_push(builder, {
        .code = CascOpcode.CASC, .site = index, .line = site.line,
    });
    builder.line++;
    return index;
}

fn void casc_body(CascBuilder* builder, int index, CascOp op) {
    CascSite* site = &builder.program.sites[index];
    assert(site.body_len >= 0 && site.body_len < CASC_BODY_MAX);
    op.line = builder.line;
    site.body[site.body_len] = op;
    site.body_len++;
    casc_write(builder, &site.body[site.body_len - 1], true);
    builder.line++;
}

fn void casc_end(CascBuilder* builder) {
    builder.source.append("endc\n");
    builder.line++;
}

fn void casc_mov(CascBuilder* builder, int reg, long value) {
    casc_emit(builder, { .code = CascOpcode.MOV_IMM, .dst = reg, .literal = value });
}

fn void casc_load(CascBuilder* builder, int reg, int cell) {
    casc_emit(builder, { .code = CascOpcode.LOAD, .dst = reg, .cell = cell });
}

fn void casc_store(CascBuilder* builder, int cell, int reg) {
    casc_emit(builder, { .code = CascOpcode.STORE, .left = reg, .cell = cell });
}

fn void casc_print(CascBuilder* builder, int reg) {
    casc_emit(builder, { .code = CascOpcode.PRINT, .left = reg });
}

fn void casc_load_print(CascBuilder* builder, int cell, int reg) {
    casc_load(builder, reg, cell);
    casc_print(builder, reg);
}

fn void casc_probe(CascBuilder* builder, int cell) {
    casc_emit(builder, { .code = CascOpcode.PROBE, .cell = cell });
}

fn void casc_med(CascBuilder* builder, int cell) {
    casc_emit(builder, { .code = CascOpcode.MED_OUT, .cell = cell });
}

fn void casc_await_print(CascBuilder* builder, int reg) {
    casc_emit(builder, { .code = CascOpcode.AWAIT, .dst = reg });
    casc_print(builder, reg);
}

fn void casc_extra(CascBuilder* builder, int site, int count) {
    for (int i = 0; i < count; i++) {
        casc_body(builder, site, {
            .code = CascOpcode.ADD, .dst = 2, .left = 2, .literal = 1,
        });
        casc_body(builder, site, { .code = CascOpcode.PRINT, .left = 2 });
    }
}

fn int casc_increment_site(CascBuilder* builder, int input, bool is_async,
        OracleWorld world, bool snapshot) {
    int site = casc_start(builder, input, is_async);
    if (snapshot) {
        for (int reg = 0; reg < 16; reg++) {
            casc_body(builder, site, {
                .code = CascOpcode.PRINT, .left = reg, .snapshot_probe = true,
            });
        }
    }
    casc_body(builder, site, { .code = CascOpcode.LOAD, .dst = 0, .cell = input });
    casc_body(builder, site, { .code = CascOpcode.INC, .dst = 0 });
    casc_extra(builder, site, world.prefix_ops);
    casc_body(builder, site, { .code = CascOpcode.STORE, .left = 0, .cell = input });
    casc_end(builder);
    return site;
}

fn void casc_sync_success(CascBuilder* builder, OracleWorld world) {
    long value = (long)(world.seed % 17) + 1;
    casc_mov(builder, 0, value);
    casc_store(builder, 0, 0);
    casc_increment_site(builder, 0, false, world, false);
    casc_med(builder, 2);
    casc_load_print(builder, 0, 1);
    casc_load_print(builder, 2, 2);
    casc_probe(builder, 2);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_sync_abort(CascBuilder* builder, OracleWorld world) {
    casc_mov(builder, 15, world.loop_trips);
    int label = builder.program.len;
    casc_emit(builder, { .code = CascOpcode.LABEL, .literal = label });
    casc_increment_site(builder, 0, false, world, false);
    casc_med(builder, 2);
    casc_emit(builder, { .code = CascOpcode.DECAY_MAIN });
    casc_emit(builder, { .code = CascOpcode.DEC, .dst = 15 });
    casc_emit(builder, { .code = CascOpcode.BRNZ, .left = 15, .target = label });
    casc_probe(builder, 2);
    casc_print(builder, 15);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_caller_probes(CascBuilder* builder, int skip) {
    for (int reg = 0; reg < 16; reg++) {
        if (reg == skip) continue;
        casc_emit(builder, {
            .code = CascOpcode.PRINT, .left = reg, .caller_probe = true,
        });
    }
}

fn void casc_async_fifo(CascBuilder* builder, OracleWorld world) {
    casc_mov(builder, 0, (long)(world.seed % 17) + 1);
    casc_store(builder, 0, 0);
    casc_mov(builder, 0, (long)(world.seed % 17) + 11);
    casc_store(builder, 1, 0);
    for (int i = 0; i < world.cascade_tasks; i++) {
        for (int reg = 0; reg < 16; reg++) {
            casc_mov(builder, reg, (long)(i * 100 + reg + 1));
        }
        casc_increment_site(builder, i % 2, true, world, true);
        casc_med(builder, i + 2);
    }
    for (int reg = 0; reg < 16; reg++) casc_mov(builder, reg, (long)(1000 + reg));
    if (world.seed % 8 == 3) {
        casc_emit(builder, { .code = CascOpcode.RET });
        return;
    }
    casc_await_print(builder, 2);
    casc_caller_probes(builder, 2);
    casc_load_print(builder, 0, 3);
    casc_load_print(builder, 1, 4);
    for (int i = 0; i < world.cascade_tasks; i++) casc_probe(builder, i + 2);
    casc_await_print(builder, 5);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_pending_out(CascBuilder* builder, OracleWorld world) {
    casc_increment_site(builder, 0, true, world, false);
    casc_med(builder, 2);
    casc_probe(builder, 2);
    casc_load(builder, 1, 2);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_async_abort(CascBuilder* builder, OracleWorld world) {
    casc_increment_site(builder, 0, true, world, false);
    casc_med(builder, 2);
    casc_increment_site(builder, 2, true, world, false);
    casc_med(builder, 3);
    casc_probe(builder, 3);
    casc_await_print(builder, 0);
    casc_probe(builder, 3);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_repeat_pending(CascBuilder* builder, OracleWorld world) {
    casc_mov(builder, 15, world.loop_trips);
    int label = builder.program.len;
    casc_emit(builder, { .code = CascOpcode.LABEL, .literal = label });
    casc_increment_site(builder, 0, true, world, false);
    casc_emit(builder, { .code = CascOpcode.DEC, .dst = 15 });
    casc_emit(builder, { .code = CascOpcode.BRNZ, .left = 15, .target = label });
    casc_await_print(builder, 0);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_queue_full(CascBuilder* builder, OracleWorld world) {
    for (int i = 0; i < world.cascade_tasks; i++) {
        int site = casc_start(builder, 0, true);
        casc_body(builder, site, { .code = CascOpcode.LOAD, .dst = 0, .cell = 0 });
        casc_end(builder);
        casc_med(builder, i + 2);
    }
    casc_await_print(builder, 0);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_async_body_fault(CascBuilder* builder, OracleWorld world) {
    casc_mov(builder, 0, 9223372036854775807);
    casc_store(builder, 0, 0);
    int site = casc_start(builder, 0, true);
    casc_body(builder, site, { .code = CascOpcode.LOAD, .dst = 0, .cell = 0 });
    casc_body(builder, site, { .code = CascOpcode.CADD, .dst = 0, .left = 0, .literal = 1 });
    casc_extra(builder, site, world.prefix_ops);
    casc_body(builder, site, { .code = CascOpcode.STORE, .left = 0, .cell = 0 });
    casc_end(builder);
    casc_med(builder, 2);
    casc_await_print(builder, 0);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_async_cancel(CascBuilder* builder) {
    int good = casc_start(builder, 0, true);
    casc_body(builder, good, { .code = CascOpcode.LOAD, .dst = 0, .cell = 0 });
    casc_body(builder, good, { .code = CascOpcode.INC, .dst = 0 });
    casc_body(builder, good, { .code = CascOpcode.STORE, .left = 0, .cell = 0 });
    casc_body(builder, good, { .code = CascOpcode.PRINT, .left = 0 });
    casc_end(builder);
    casc_med(builder, 2);
    int bad = casc_start(builder, 0, true);
    casc_body(builder, bad, { .code = CascOpcode.LOAD, .dst = 0, .cell = 0 });
    casc_body(builder, bad, {
        .code = CascOpcode.CADD, .dst = 0, .left = 0,
        .literal = 9223372036854775807,
    });
    casc_end(builder);
    casc_med(builder, 3);
    int later = casc_start(builder, 0, true);
    casc_body(builder, later, { .code = CascOpcode.MOV_IMM, .dst = 0, .literal = 99 });
    casc_body(builder, later, { .code = CascOpcode.PRINT, .left = 0 });
    casc_body(builder, later, { .code = CascOpcode.STORE, .left = 0, .cell = 0 });
    casc_end(builder);
    casc_med(builder, 4);
    casc_emit(builder, { .code = CascOpcode.AWAIT, .dst = 15 });
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn void casc_async_reenqueue(CascBuilder* builder, OracleWorld world) {
    casc_mov(builder, 15, world.loop_trips);
    int label = builder.program.len;
    casc_emit(builder, { .code = CascOpcode.LABEL, .literal = label });
    casc_increment_site(builder, 0, true, world, false);
    casc_med(builder, 2);
    casc_probe(builder, 2);
    casc_emit(builder, { .code = CascOpcode.AWAIT, .dst = 1 });
    casc_emit(builder, { .code = CascOpcode.DEC, .dst = 15 });
    casc_emit(builder, { .code = CascOpcode.BRNZ, .left = 15, .target = label });
    casc_probe(builder, 2);
    casc_await_print(builder, 2);
    casc_emit(builder, { .code = CascOpcode.RET });
}

fn bool casc_validate(CascBuilder* builder) {
    if (builder.program.len < 1 ||
            builder.program.ops[builder.program.len - 1].code != CascOpcode.RET) {
        return false;
    }
    for (int i = 0; i < builder.program.len; i++) {
        CascOp op = builder.program.ops[i];
        if (op.code == CascOpcode.BRNZ &&
                (op.target < 0 || op.target >= builder.program.len)) return false;
        if (op.code == CascOpcode.CASC &&
                (op.site < 0 || op.site >= builder.program.site_count)) return false;
    }
    return true;
}

fn CascBuilder* cascade_oracle_generate(OracleWorld world) {
    bool sync_home = world.cascade_scenario == CascScenario.SYNC_SUCCESS ||
        world.cascade_scenario == CascScenario.SYNC_ABORT;
    CascBuilder* builder = casc_builder(sync_home);
    switch (world.cascade_scenario) {
        case CascScenario.SYNC_SUCCESS: casc_sync_success(builder, world);
        case CascScenario.SYNC_ABORT: casc_sync_abort(builder, world);
        case CascScenario.ASYNC_FIFO: casc_async_fifo(builder, world);
        case CascScenario.PENDING_OUT: casc_pending_out(builder, world);
        case CascScenario.ASYNC_ABORT: casc_async_abort(builder, world);
        case CascScenario.REPEAT_PENDING: casc_repeat_pending(builder, world);
        case CascScenario.QUEUE_FULL: casc_queue_full(builder, world);
        case CascScenario.ASYNC_BODY_FAULT: casc_async_body_fault(builder, world);
        case CascScenario.ASYNC_CANCEL: casc_async_cancel(builder);
        case CascScenario.ASYNC_REENQUEUE: casc_async_reenqueue(builder, world);
    }
    assert(casc_validate(builder));
    return builder;
}

fn bool cascade_oracle_world_fails(OracleWorld world) {
    CascBuilder* builder = cascade_oracle_generate(world);
    OwnershipCase expected = cascade_oracle_reference(&builder.program);
    expected.source = builder.source.str_view();
    int? result = run_ownership_case(expected, "cascade-oracle-shrink.rza", false);
    if (catch result) {
        io::eprintn("cascade oracle harness error");
        return true;
    }
    if (result != 0) io::eprintfn("cascade oracle predicate status=%d", result);
    return result != 0;
}

fn bool cascade_oracle_synthetic_failure(OracleWorld world) {
    return world.cascade_scenario == CascScenario.REPEAT_PENDING && world.loop_trips >= 2;
}

fn int cascade_oracle_shrink_selftest() {
    OracleWorld world = cascade_oracle_world(0xCA5C);
    world.cascade_scenario = CascScenario.REPEAT_PENDING;
    world.loop_trips = 4;
    OracleWorld reduced = oracle_shrink(world, &cascade_oracle_synthetic_failure);
    CascBuilder* builder = cascade_oracle_generate(reduced);
    if (!expect(reduced.loop_trips == 2 && reduced.seed == world.seed && casc_validate(builder),
            "cascade shrink preserves failure, seed and CFG")) return 1;
    return 0;
}

fn int? cascade_oracle_run_case(ulong seed) {
    OracleWorld world = cascade_oracle_world(seed);
    if (!cascade_oracle_world_fails(world)) {
        oracle_coverage.cascade_cases[(int)world.cascade_scenario]++;
        return 0;
    }
    OracleWorld reduced = oracle_shrink(world, &cascade_oracle_world_fails);
    io::eprintfn("cascade oracle seed=%d scenario=%d tasks=%d trips=%d",
        reduced.seed, (int)reduced.cascade_scenario, reduced.cascade_tasks,
        reduced.loop_trips);
    CascBuilder* builder = cascade_oracle_generate(reduced);
    io::eprintn(builder.source.str_view());
    return 1;
}

fn int cascade_cancel_state_checks() {
    OracleWorld world = { .cascade_scenario = CascScenario.ASYNC_CANCEL };
    CascBuilder* builder = cascade_oracle_generate(world);
    CascRuntime state = {
        .cells = builder.program.cells,
        .main_alive = true,
        .output = dstring::temp(),
        .errors = dstring::temp(),
    };
    cascade_oracle_execute(&builder.program, &state);
    if (!expect(state.status == 1 && state.count == 0 && state.regs[15] == 1,
            "fault returns completed count and cancels the remaining queue")) return 1;
    if (!expect(state.cells[0].value == 1 && !state.cells[4].published &&
            state.output.str_view() == "1\n" &&
            state.errors.str_view().contains("arithmetic overflow"),
            "cancelled task neither executes nor publishes output")) return 1;
    for (int i = 0; i < builder.program.site_count; i++) {
        if (!expect(!state.pending[i], "fault clears every pending flag")) return 1;
    }
    return 0;
}

fn int? cascade_oracle_run() {
    if (cascade_oracle_shrink_selftest() != 0) return 1;
    for (ulong seed = 1; seed <= 40; seed++) {
        if (cascade_oracle_run_case(seed)! != 0) return 1;
    }
    if (cascade_cancel_state_checks() != 0) return 1;
    if (!cascade_oracle_coverage_ok()) return 1;
    io::printn("CASCADE_ORACLE OK (40 programs)");
    return 0;
}
