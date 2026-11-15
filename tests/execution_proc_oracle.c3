module rza_tests;

import std::core::dstring;
import std::io;

const int PROC_ORACLE_PROCS_MAX = 2;
const int PROC_ORACLE_OPS_MAX = 56;
const int PROC_ORACLE_TOP_OPS_MAX = 96;

enum ProcFaultMode : char {
    NONE,
    DEAD_AFTER_RET,
    ARENA_EXHAUSTION,
}

enum ProcOpcode : char {
    MOV_IMM,
    MOV_REG,
    ADD,
    SUB,
    MUL,
    SLT,
    AND,
    LOAD,
    STORE,
    PRINT,
    INC,
    DEC,
    LABEL,
    BRNZ,
    CALL,
    RES,
    RET,
}

struct ProcOp {
    ProcOpcode code;
    int dst;
    int left;
    int right;
    int target;
    int home;
    int line;
    long literal;
    bool literal_rhs;
    bool entry_probe;
    bool restore_probe;
}

struct ProcProcedure {
    ProcOp[PROC_ORACLE_OPS_MAX] ops;
    int len;
}

struct ProcProgram {
    ProcProcedure[PROC_ORACLE_PROCS_MAX] procs;
    int proc_count;
    ProcOp[PROC_ORACLE_TOP_OPS_MAX] top;
    int top_len;
}

fn OracleWorld proc_oracle_world(ulong seed) {
    OracleRng config = { seed ^ 0xd1b54a32d192ed03 };
    OracleWorld world = {
        .seed = seed,
        .prefix_ops = 1 + config.below(4),
        .loop_trips = 2 + config.below(2),
        .proc_count = 1 + config.below(PROC_ORACLE_PROCS_MAX),
        .proc_calls = 1 + config.below(3),
        .nested_calls = config.below(2) == 1,
        .proc_fault = (ProcFaultMode)config.below(3),
    };
    if (world.proc_count == 2 && world.proc_fault != ProcFaultMode.NONE) {
        world.nested_calls = true;
    }
    return world;
}

fn ProcOp proc_op(ProcOpcode code, int home) {
    return { .code = code, .home = home };
}

fn void proc_push(ProcProcedure* proc, ProcOp op) {
    assert(proc.len >= 0 && proc.len < PROC_ORACLE_OPS_MAX);
    proc.ops[proc.len] = op;
    proc.len++;
}

fn void proc_push_top(ProcProgram* program, ProcOp op) {
    assert(program.top_len >= 0 && program.top_len < PROC_ORACLE_TOP_OPS_MAX);
    program.top[program.top_len] = op;
    program.top_len++;
}

fn ProcOp proc_random_op(OracleRng* rng, int home) {
    int choice = rng.below(12);
    ProcOp op = proc_op(ProcOpcode.MOV_IMM, -1);
    op.dst = rng.below(14);
    op.left = rng.below(14);
    op.right = rng.below(14);
    op.literal = oracle_random_i64(rng);
    op.literal_rhs = rng.below(2) == 1;
    switch (choice) {
        case 0: op.code = ProcOpcode.MOV_IMM;
        case 1: op.code = ProcOpcode.MOV_REG;
        case 2: op.code = ProcOpcode.ADD;
        case 3: op.code = ProcOpcode.SUB;
        case 4: op.code = ProcOpcode.MUL;
        case 5: op.code = ProcOpcode.SLT;
        case 6: op.code = ProcOpcode.AND;
        case 7:
            op.code = ProcOpcode.LOAD;
            op.home = home;
            op.literal = 0;
            op.literal_rhs = true;
        case 8:
            op.code = ProcOpcode.STORE;
            op.home = home;
            op.literal = 0;
            op.literal_rhs = true;
        case 9: op.code = ProcOpcode.PRINT;
        case 10: op.code = ProcOpcode.INC;
        default: op.code = ProcOpcode.DEC;
    }
    return op;
}

fn void proc_add_global_update(ProcProcedure* proc, int pi) {
    proc_push(proc, {
        .code = ProcOpcode.LOAD, .dst = 8, .home = -1, .literal_rhs = true,
    });
    proc_push(proc, {
        .code = ProcOpcode.ADD, .dst = 8, .left = 8, .home = -1,
        .literal = (long)(pi + 1), .literal_rhs = true,
    });
    proc_push(proc, {
        .code = ProcOpcode.STORE, .left = 8, .home = -1, .literal_rhs = true,
    });
}

fn ProcOp proc_register_probe(int reg, bool entry) {
    return {
        .code = ProcOpcode.PRINT, .left = reg, .home = -1,
        .entry_probe = entry, .restore_probe = !entry,
    };
}

fn void proc_add_nested_calls(ProcProcedure* proc, OracleWorld world) {
    proc_push(proc, {
        .code = ProcOpcode.MOV_IMM, .dst = 7, .home = -1, .literal = 202,
    });
    proc_push(proc, {
        .code = ProcOpcode.MOV_IMM, .dst = 15, .home = -1,
        .literal = world.loop_trips,
    });
    int label = proc.len;
    proc_push(proc, { .code = ProcOpcode.LABEL, .literal = label, .home = -1 });
    proc_push(proc, { .code = ProcOpcode.CALL, .target = 0, .home = -1 });
    proc_push(proc, { .code = ProcOpcode.DEC, .dst = 15, .home = -1 });
    proc_push(proc, {
        .code = ProcOpcode.BRNZ, .left = 15, .target = label, .home = -1,
    });
    for (int reg = 0; reg < 16; reg++) proc_push(proc, proc_register_probe(reg, false));
}

fn ProcProcedure proc_generate_proc(OracleWorld world, int pi, OracleRng* rng) {
    ProcProcedure proc = {};
    for (int reg = 0; reg < 16; reg++) {
        proc_push(&proc, proc_register_probe(reg, true));
    }
    if (pi == 0 && world.proc_fault == ProcFaultMode.ARENA_EXHAUSTION) {
        proc_push(&proc, {
            .code = ProcOpcode.MOV_IMM, .dst = 15, .home = -1, .literal = 2,
        });
        int label = proc.len;
        proc_push(&proc, { .code = ProcOpcode.LABEL, .literal = label, .home = -1 });
        proc_push(&proc, { .code = ProcOpcode.RES, .dst = 64, .home = pi });
        proc_push(&proc, { .code = ProcOpcode.DEC, .dst = 15, .home = -1 });
        proc_push(&proc, {
            .code = ProcOpcode.BRNZ, .left = 15, .target = label, .home = -1,
        });
        proc_push(&proc, proc_op(ProcOpcode.RET, -1));
        return proc;
    }
    proc_push(&proc, { .code = ProcOpcode.RES, .dst = 64, .home = pi });
    proc_push(&proc, {
        .code = ProcOpcode.LOAD, .dst = 0, .home = pi, .literal_rhs = true,
    });
    proc_push(&proc, { .code = ProcOpcode.PRINT, .left = 0, .home = -1 });
    for (int i = 0; i < world.prefix_ops; i++) {
        proc_push(&proc, proc_random_op(rng, pi));
    }
    if (pi == 1 && world.nested_calls) proc_add_nested_calls(&proc, world);
    proc_add_global_update(&proc, pi);
    proc_push(&proc, {
        .code = ProcOpcode.MOV_IMM, .dst = 7, .home = -1, .literal = (long)(100 + pi),
    });
    proc_push(&proc, proc_op(ProcOpcode.RET, -1));
    return proc;
}

fn void proc_generate_top(ProcProgram* program, OracleWorld world) {
    for (int reg = 0; reg < 16; reg++) {
        proc_push_top(program, {
            .code = ProcOpcode.MOV_IMM, .dst = reg, .home = -1,
            .literal = (long)(1000 + reg),
        });
    }
    for (int i = 0; i < world.proc_calls && world.proc_count > 0; i++) {
        proc_push_top(program, {
            .code = ProcOpcode.CALL, .target = world.proc_count - 1, .home = -1,
        });
        for (int reg = 0; reg < 16; reg++) {
            proc_push_top(program, proc_register_probe(reg, false));
        }
        proc_push_top(program, {
            .code = ProcOpcode.LOAD, .dst = 6, .home = -1, .literal_rhs = true,
        });
        proc_push_top(program, { .code = ProcOpcode.PRINT, .left = 6, .home = -1 });
    }
    if (world.proc_fault == ProcFaultMode.DEAD_AFTER_RET && world.proc_count > 0) {
        proc_push_top(program, {
            .code = ProcOpcode.LOAD, .dst = 5, .home = 0, .literal_rhs = true,
        });
    }
    proc_push_top(program, proc_op(ProcOpcode.RET, -1));
}

fn ProcProgram proc_oracle_generate(OracleWorld world) {
    assert(world.proc_count >= 0 && world.proc_count <= PROC_ORACLE_PROCS_MAX);
    ProcProgram program = { .proc_count = world.proc_count };
    OracleRng rng = { world.seed };
    for (int pi = 0; pi < world.proc_count; pi++) {
        program.procs[pi] = proc_generate_proc(world, pi, &rng);
    }
    proc_generate_top(&program, world);
    return program;
}

fn String proc_memory_name(ProcOp op, bool in_proc) {
    if (op.home < 0) return "cells_m";
    if (!in_proc) return string::tformat("p%d_dead_m", op.home);
    return string::tformat("p%d_m", op.home);
}

fn String proc_offset(ProcOp op) {
    if (op.literal_rhs) return string::tformat("%d", op.literal);
    return string::tformat("%%r%d", op.right);
}

fn void proc_emit_op(DString* source, ProcOp* op, int* line, bool in_proc) {
    op.line = *line;
    if (in_proc) source.append("    ");
    switch (op.code) {
        case ProcOpcode.MOV_IMM:
            source.appendf("mov %%r%d, %d\n", op.dst, op.literal);
        case ProcOpcode.MOV_REG:
            source.appendf("mov %%r%d, %%r%d\n", op.dst, op.left);
        case ProcOpcode.ADD: case ProcOpcode.SUB: case ProcOpcode.MUL:
        case ProcOpcode.SLT: case ProcOpcode.AND:
            String[] names = { "add", "sub", "mul", "slt", "and" };
            String rhs = op.literal_rhs ? string::tformat("%d", op.literal) :
                string::tformat("%%r%d", op.right);
            source.appendf("%s %%r%d, %%r%d, %s\n", names[(int)op.code - 2],
                op.dst, op.left, rhs);
        case ProcOpcode.LOAD:
            source.appendf("load %%r%d, [%s + %s]\n", op.dst,
                proc_memory_name(*op, in_proc), proc_offset(*op));
        case ProcOpcode.STORE:
            source.appendf("store [%s + %s], %%r%d\n",
                proc_memory_name(*op, in_proc), proc_offset(*op), op.left);
        case ProcOpcode.PRINT: source.appendf("print %%r%d\n", op.left);
        case ProcOpcode.INC: source.appendf("inc %%r%d\n", op.dst);
        case ProcOpcode.DEC: source.appendf("dec %%r%d\n", op.dst);
        case ProcOpcode.LABEL: source.appendf("l%d:\n", op.literal);
        case ProcOpcode.BRNZ:
            source.appendf("brnz %%r%d, l%d\n", op.left, op.target);
        case ProcOpcode.CALL: source.appendf("call p%d\n", op.target);
        case ProcOpcode.RES:
            source.appendf("res p%d_cell, p%d, %d\n", op.home, op.home, op.dst);
            source.appendf("    med p%d_m, p%d_cell, p%d\n", op.home, op.home, op.home);
        case ProcOpcode.RET: source.append("ret\n");
    }
    *line = *line + (op.code == ProcOpcode.RES ? 2 : 1);
}

fn String proc_oracle_source_finish(ProcProgram* program, DString source, int line,
        ProcFaultMode fault_mode) {
    if (fault_mode == ProcFaultMode.DEAD_AFTER_RET && program.proc_count > 0) {
        source.append("med p0_dead_m, p0_cell, field\n");
        line++;
    }
    for (int i = 0; i < program.top_len; i++) {
        proc_emit_op(&source, &program.top[i], &line, false);
    }
    return source.str_view();
}

fn String proc_oracle_source_full(ProcProgram* program, ProcFaultMode fault_mode) {
    DString source = dstring::temp("res cells, field, 64\nmed cells_m, cells, field\n");
    int line = 3;
    for (int pi = 0; pi < program.proc_count; pi++) {
        source.appendf("proc p%d:\n", pi);
        line++;
        for (int i = 0; i < program.procs[pi].len; i++) {
            proc_emit_op(&source, &program.procs[pi].ops[i], &line, true);
        }
    }
    return proc_oracle_source_finish(program, source, line, fault_mode);
}

fn bool proc_oracle_world_fails(OracleWorld world) {
    ProcProgram program = proc_oracle_generate(world);
    String source = proc_oracle_source_full(&program, world.proc_fault);
    OwnershipCase expected = proc_oracle_reference(&program);
    expected.source = source;
    int? result = run_ownership_case(expected, "proc-oracle-shrink.rza", false);
    if (catch result) {
        io::eprintn("proc oracle harness error");
        return true;
    }
    if (result != 0) io::eprintfn("proc oracle predicate status=%d", result);
    return result != 0;
}

fn bool proc_oracle_synthetic_failure(OracleWorld world) {
    return world.proc_count >= 1 && world.proc_calls >= 2 &&
        world.proc_fault == ProcFaultMode.DEAD_AFTER_RET;
}

fn int proc_oracle_shrink_selftest() {
    OracleWorld stale = { .proc_count = 2, .nested_calls = true };
    oracle_dimension_set(&stale, OracleDimension.PROC_COUNT, 1);
    if (!expect(!stale.nested_calls, "proc shrink canonicalizes impossible nested calls")) {
        return 1;
    }
    OracleWorld world = proc_oracle_world(0x51A7);
    world.proc_count = 2;
    world.proc_calls = 4;
    world.proc_fault = ProcFaultMode.DEAD_AFTER_RET;
    OracleWorld reduced = oracle_shrink(world, &proc_oracle_synthetic_failure);
    if (!expect(reduced.proc_count == 1 && reduced.proc_calls == 2 &&
            reduced.proc_fault == ProcFaultMode.DEAD_AFTER_RET && reduced.seed == world.seed,
            "proc shrink preserves procedure failure and seed")) return 1;
    return 0;
}

fn int? proc_oracle_run_case(ulong seed) {
    OracleWorld world = proc_oracle_world(seed);
    if (!proc_oracle_world_fails(world)) return 0;
    OracleWorld reduced = oracle_shrink(world, &proc_oracle_world_fails);
    io::eprintfn("proc oracle seed=%d procs=%d calls=%d nested=%s fault=%d",
        reduced.seed, reduced.proc_count, reduced.proc_calls,
        reduced.nested_calls ? "yes" : "no", (int)reduced.proc_fault);
    ProcProgram program = proc_oracle_generate(reduced);
    io::eprintn(proc_oracle_source_full(&program, reduced.proc_fault));
    return 1;
}

fn int? proc_oracle_run() {
    if (proc_oracle_shrink_selftest() != 0) return 1;
    for (ulong seed = 1; seed <= 64; seed++) {
        if (proc_oracle_run_case(seed)! != 0) return 1;
    }
    if (!proc_oracle_coverage_ok()) return 1;
    io::printn("PROC_ORACLE OK (64 programs)");
    return 0;
}
