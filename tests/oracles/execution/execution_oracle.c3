module rza_tests;

import libc;
import std::core::dstring;
import std::io;

const int ORACLE_OPS_MAX = 64;
bool oracle_view_mutation = false;
const int ORACLE_STEP_LIMIT = 1024;
const int128 ORACLE_I64_MAX = 9223372036854775807;
const int128 ORACLE_I64_MIN = -9223372036854775807 - 1;

enum OracleOpcode : char {
    MOV_IMM,
    MOV_REG,
    ADD,
    SUB,
    MUL,
    CADD,
    CSUB,
    CMUL,
    DIV,
    MOD,
    SHL,
    SHR,
    USHR,
    SLT,
    AND,
    LOAD,
    STORE,
    PRINT,
    INC,
    DEC,
    CINC,
    CDEC,
    LABEL,
    BRZ,
    BRNZ,
    VIEW,
    RET,
}

enum ViewScenario : char {
    NONE,
    VALID,
    NESTED,
    EMPTY,
    INVALID,
    NESTED_INVALID,
}

struct OracleOp {
    OracleOpcode code;
    int dst;
    int left;
    int right;
    int target;
    int med;
    long literal;
    long view_length;
    bool literal_rhs;
    bool view_length_immediate;
}

struct OracleProgram {
    OracleOp[ORACLE_OPS_MAX] ops;
    int len;
}

struct OracleMed {
    ulong offset;
    ulong size;
    bool valid;
}

struct OracleWorld {
    ulong seed;
    int prefix_ops;
    int forward_ops;
    int loop_ops;
    int suffix_ops;
    int loop_trips;
    bool forward_branch;
    bool backward_loop;
    bool branch_on_zero;
    int proc_count;
    int proc_calls;
    bool nested_calls;
    ProcFaultMode proc_fault;
    CascScenario cascade_scenario;
    int cascade_tasks;
    ViewScenario view_scenario;
}

struct OracleRng {
    ulong state;
}

fn ulong OracleRng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn int OracleRng.below(&self, int limit) {
    assert(limit > 0);
    return (int)(self.next() % (ulong)limit);
}

fn long oracle_random_i64(OracleRng* rng) {
    long[] edges = {
        -9223372036854775807 - 1, -9223372036854775807, -1, 0, 1,
        9223372036854775806, 9223372036854775807, 2, -2, 56
    };
    if (rng.below(3) == 0) return edges[rng.below((int)edges.len)];
    ulong raw = rng.next();
    if (raw <= (ulong)ORACLE_I64_MAX) return (long)raw;
    return -1 - (long)(18446744073709551615 - raw);
}

fn OracleWorld oracle_world(ulong seed) {
    OracleRng config = { seed ^ 0x9e3779b97f4a7c15 };
    return {
        .seed = seed,
        .prefix_ops = 2 + config.below(3),
        .forward_ops = 1 + config.below(2),
        .loop_ops = 1 + config.below(3),
        .suffix_ops = 2 + config.below(3),
        .loop_trips = 1 + config.below(3),
        .forward_branch = config.below(2) == 1,
        .backward_loop = config.below(2) == 1,
        .branch_on_zero = config.below(2) == 0,
    };
}

fn void oracle_push(OracleProgram* program, OracleOp op) {
    assert(program.len >= 0 && program.len < ORACLE_OPS_MAX);
    program.ops[program.len] = op;
    program.len++;
}

fn int oracle_target_reg(OracleRng* rng) {
    return rng.below(14);
}

fn void oracle_random_op(OracleProgram* program, OracleRng* rng) {
    int choice = rng.below(22);
    OracleOp op = {};
    op.dst = oracle_target_reg(rng);
    op.left = oracle_target_reg(rng);
    op.right = oracle_target_reg(rng);
    op.literal = oracle_random_i64(rng);
    op.literal_rhs = rng.below(2) == 1;
    switch (choice) {
        case 0:
            op.code = OracleOpcode.MOV_IMM;
        case 1:
            op.code = OracleOpcode.MOV_REG;
        case 2: op.code = OracleOpcode.ADD;
        case 3: op.code = OracleOpcode.SUB;
        case 4: op.code = OracleOpcode.MUL;
        case 5: op.code = OracleOpcode.CADD;
        case 6: op.code = OracleOpcode.CSUB;
        case 7: op.code = OracleOpcode.CMUL;
        case 8: op.code = OracleOpcode.DIV;
        case 9: op.code = OracleOpcode.MOD;
        case 10: op.code = OracleOpcode.SHL;
        case 11: op.code = OracleOpcode.SHR;
        case 12: op.code = OracleOpcode.USHR;
        case 13: op.code = OracleOpcode.SLT;
        case 14:
            op.code = OracleOpcode.AND;
            op.literal = 56;
            op.literal_rhs = true;
        case 15: op.code = OracleOpcode.LOAD;
        case 16: op.code = OracleOpcode.STORE;
        case 17: op.code = OracleOpcode.PRINT;
        case 18: op.code = OracleOpcode.INC;
        case 19: op.code = OracleOpcode.DEC;
        case 20: op.code = OracleOpcode.CINC;
        default: op.code = OracleOpcode.CDEC;
    }
    oracle_push(program, op);
}

fn void oracle_random_ops(OracleProgram* program, OracleRng* rng, int count) {
    assert(count >= 0);
    for (int i = 0; i < count; i++) oracle_random_op(program, rng);
}

fn void oracle_generate_view(OracleProgram* program, ViewScenario scenario) {
    if (scenario == ViewScenario.INVALID) {
        oracle_push(program, {
            .code = OracleOpcode.MOV_IMM, .dst = 0,
            .literal = 9223372036854775807, .literal_rhs = true,
        });
        oracle_push(program, {
            .code = OracleOpcode.VIEW, .med = 1, .right = 0,
            .view_length = 8, .view_length_immediate = true,
        });
        return;
    }
    if (scenario == ViewScenario.NESTED_INVALID) {
        oracle_push(program, { .code = OracleOpcode.MOV_IMM, .dst = 0, .literal = 4 });
        oracle_push(program, {
            .code = OracleOpcode.VIEW, .med = 1, .literal_rhs = true,
        });
        oracle_push(program, {
            .code = OracleOpcode.VIEW, .med = 2, .left = 1, .literal_rhs = true,
            .view_length = 8, .view_length_immediate = true,
        });
        return;
    }
    if (scenario == ViewScenario.EMPTY) {
        oracle_push(program, {
            .code = OracleOpcode.VIEW, .med = 1, .literal = 64, .literal_rhs = true,
            .view_length_immediate = true,
        });
        return;
    }
    if (scenario == ViewScenario.NONE) return;
    oracle_push(program, {
        .code = OracleOpcode.VIEW, .med = 1, .literal = 8, .literal_rhs = true,
        .view_length = 16, .view_length_immediate = true,
    });
    int med = 1;
    if (scenario == ViewScenario.NESTED) {
        oracle_push(program, {
            .code = OracleOpcode.VIEW, .med = 2, .left = 1, .literal = 4,
            .literal_rhs = true, .view_length = 8, .view_length_immediate = true,
        });
        med = 2;
    }
    oracle_push(program, { .code = OracleOpcode.MOV_IMM, .dst = 0 });
    oracle_push(program, { .code = OracleOpcode.LOAD, .dst = 1, .right = 0, .med = med });
    oracle_push(program, { .code = OracleOpcode.PRINT, .left = 1 });
}

fn OracleProgram oracle_generate(OracleWorld world) {
    OracleProgram program = {};
    OracleRng rng = { world.seed };
    oracle_generate_view(&program, world.view_scenario);
    oracle_random_ops(&program, &rng, world.prefix_ops);
    if (world.forward_branch) {
        oracle_push(&program, {
            .code = OracleOpcode.MOV_IMM,
            .dst = 14,
            .literal = world.branch_on_zero ? 0 : 1,
            .literal_rhs = true,
        });
        int branch = program.len;
        oracle_push(&program, { .code = OracleOpcode.BRZ, .left = 14 });
        oracle_random_ops(&program, &rng, world.forward_ops);
        int label = program.len;
        oracle_push(&program, { .code = OracleOpcode.LABEL });
        program.ops[branch].target = label;
    }
    if (world.backward_loop) {
        oracle_push(&program, {
            .code = OracleOpcode.MOV_IMM,
            .dst = 15,
            .literal = world.loop_trips,
            .literal_rhs = true,
        });
        int label = program.len;
        oracle_push(&program, { .code = OracleOpcode.LABEL });
        oracle_random_ops(&program, &rng, world.loop_ops);
        oracle_push(&program, { .code = OracleOpcode.DEC, .dst = 15 });
        oracle_push(&program, {
            .code = OracleOpcode.BRNZ,
            .left = 15,
            .target = label,
        });
    }
    oracle_random_ops(&program, &rng, world.suffix_ops);
    oracle_push(&program, { .code = OracleOpcode.RET });
    assert(program.len <= ORACLE_OPS_MAX);
    return program;
}

fn String oracle_rhs(OracleOp op) {
    if (op.literal_rhs) return string::tformat("%d", op.literal);
    return string::tformat("%%r%d", op.right);
}

fn String oracle_med_name(int med) {
    String[] names = { "cells_m", "view_m", "nested_m" };
    assert(med >= 0 && med < (int)names.len);
    return names[med];
}

fn String oracle_view_length(OracleOp op) {
    if (op.view_length_immediate) return string::tformat("%d", op.view_length);
    return string::tformat("%%r%d", op.target);
}

fn String oracle_source(OracleProgram* program) {
    DString source = dstring::temp("res cells, field, 64\nmed cells_m, cells, field\n");
    for (int i = 0; i < program.len; i++) {
        OracleOp op = program.ops[i];
        switch (op.code) {
            case OracleOpcode.MOV_IMM:
                source.appendf("mov %%r%d, %d\n", op.dst, op.literal);
            case OracleOpcode.MOV_REG:
                source.appendf("mov %%r%d, %%r%d\n", op.dst, op.left);
            case OracleOpcode.ADD: case OracleOpcode.SUB: case OracleOpcode.MUL:
            case OracleOpcode.CADD: case OracleOpcode.CSUB: case OracleOpcode.CMUL:
            case OracleOpcode.DIV: case OracleOpcode.MOD: case OracleOpcode.SHL:
            case OracleOpcode.SHR: case OracleOpcode.USHR:
            case OracleOpcode.SLT: case OracleOpcode.AND:
                String[] names = {
                    "add", "sub", "mul", "cadd", "csub", "cmul", "div", "mod",
                    "shl", "shr", "ushr", "slt", "and"
                };
                int index = (int)op.code - (int)OracleOpcode.ADD;
                source.appendf("%s %%r%d, %%r%d, %s\n", names[index],
                    op.dst, op.left, oracle_rhs(op));
            case OracleOpcode.LOAD:
                source.appendf("load %%r%d, [%s + %%r%d]\n", op.dst,
                    oracle_med_name(op.med), op.right);
            case OracleOpcode.STORE:
                source.appendf("store [%s + %%r%d], %%r%d\n",
                    oracle_med_name(op.med), op.right, op.left);
            case OracleOpcode.PRINT:
                source.appendf("print %%r%d\n", op.left);
            case OracleOpcode.INC:
                source.appendf("inc %%r%d\n", op.dst);
            case OracleOpcode.DEC:
                source.appendf("dec %%r%d\n", op.dst);
            case OracleOpcode.CINC:
                source.appendf("cinc %%r%d\n", op.dst);
            case OracleOpcode.CDEC:
                source.appendf("cdec %%r%d\n", op.dst);
            case OracleOpcode.LABEL:
                source.appendf("l%d:\n", i);
            case OracleOpcode.BRZ:
                source.appendf("brz %%r%d, l%d\n", op.left, op.target);
            case OracleOpcode.BRNZ:
                source.appendf("brnz %%r%d, l%d\n", op.left, op.target);
            case OracleOpcode.VIEW:
                source.appendf("view %s, %s, %s, %s\n", oracle_med_name(op.med),
                    oracle_med_name(op.left), oracle_rhs(op), oracle_view_length(op));
            case OracleOpcode.RET:
                source.append("ret\n");
        }
    }
    return source.str_view();
}

fn long oracle_from_bits(ulong raw) {
    if (raw <= (ulong)ORACLE_I64_MAX) return (long)raw;
    return -1 - (long)(18446744073709551615 - raw);
}

fn long oracle_wrap(long left, long right, OracleOpcode code) {
    ulong result;
    if (code == OracleOpcode.ADD) {
        result = (ulong)left + (ulong)right;
    } else if (code == OracleOpcode.SUB) {
        result = (ulong)left - (ulong)right;
    } else {
        result = (ulong)left * (ulong)right;
    }
    return oracle_from_bits(result);
}

fn bool oracle_checked(long left, long right, OracleOpcode code, long* result) {
    int128 value;
    if (code == OracleOpcode.CADD) {
        value = (int128)left + (int128)right;
    } else if (code == OracleOpcode.CSUB) {
        value = (int128)left - (int128)right;
    } else {
        value = (int128)left * (int128)right;
    }
    if (value > ORACLE_I64_MAX || value < ORACLE_I64_MIN) return true;
    *result = (long)value;
    return false;
}

fn bool oracle_division(OracleOp op, long[] regs, DString* errors, int line) {
    long left = regs[op.left];
    long right = op.literal_rhs ? op.literal : regs[op.right];
    if (right == 0 || (left == ORACLE_I64_MIN && right == -1)) {
        oracle_coverage.division_faults++;
        errors.appendf("FAULT line %d: division\n", line);
        return true;
    }
    regs[op.dst] = op.code == OracleOpcode.DIV ? left / right : left % right;
    return false;
}

fn bool oracle_shift(OracleOp op, long[] regs, DString* errors, int line) {
    long right = op.literal_rhs ? op.literal : regs[op.right];
    if (right < 0 || right >= 64) {
        oracle_coverage.shift_faults++;
        errors.appendf("FAULT line %d: shift\n", line);
        return true;
    }
    uint shift = (uint)right;
    long left = regs[op.left];
    if (op.code == OracleOpcode.SHL) {
        regs[op.dst] = oracle_from_bits((ulong)left << shift);
        return false;
    }
    ulong raw = (ulong)left >> shift;
    if (op.code == OracleOpcode.SHR && left < 0 && shift > 0) {
        raw |= ~(ulong)0 << (64 - shift);
    }
    regs[op.dst] = oracle_from_bits(raw);
    return false;
}

fn bool oracle_view(OracleOp op, long[] regs, OracleMed[] meds, DString* errors, int line) {
    long offset = op.literal_rhs ? op.literal : regs[op.right];
    long length = op.view_length_immediate ? op.view_length : regs[op.target];
    OracleMed source = meds[op.left];
    meds[op.med].valid = false;
    if (!source.valid || offset < 0 || length < 0 || (ulong)offset > source.size
            || (ulong)length > source.size - (ulong)offset) {
        oracle_coverage.view_faults++;
        errors.appendf("FAULT line %d: invalid view %s\n", line, oracle_med_name(op.med));
        return true;
    }
    meds[op.med] = {
        .offset = source.offset + (ulong)offset,
        .size = (ulong)length,
        .valid = true,
    };
    oracle_coverage.view_constructions++;
    if (op.left > 0) oracle_coverage.nested_views++;
    return false;
}

fn bool oracle_memory(OracleOp op, long[] regs, OracleMed[] meds, char[] cells,
        DString* errors, int line) {
    OracleMed med = meds[op.med];
    long offset = regs[op.right];
    if (!med.valid || offset < 0 || (ulong)offset > med.size
            || 8 > med.size - (ulong)offset) {
        oracle_coverage.bounds_faults++;
        errors.appendf("FAULT line %d: out of bounds %s\n", line, oracle_med_name(op.med));
        return true;
    }
    ulong physical = med.offset + (ulong)offset;
    assert(physical <= 56);
    if (op.code == OracleOpcode.LOAD) {
        libc::memcpy(&regs[op.dst], &cells[(sz)physical], 8);
    } else {
        libc::memcpy(&cells[(sz)physical], &regs[op.left], 8);
    }
    return false;
}

fn bool oracle_apply(OracleOp op, long[] regs, DString* errors, int line) {
    long left = regs[op.left];
    long right = op.literal_rhs ? op.literal : regs[op.right];
    if (op.code == OracleOpcode.DIV || op.code == OracleOpcode.MOD) {
        return oracle_division(op, regs, errors, line);
    }
    if (op.code == OracleOpcode.SHL || op.code == OracleOpcode.SHR ||
            op.code == OracleOpcode.USHR) {
        return oracle_shift(op, regs, errors, line);
    }
    if (op.code == OracleOpcode.SLT) {
        regs[op.dst] = left < right ? 1 : 0;
        return false;
    }
    if (op.code == OracleOpcode.AND) {
        regs[op.dst] = left & right;
        return false;
    }
    if (op.code == OracleOpcode.CADD || op.code == OracleOpcode.CSUB ||
            op.code == OracleOpcode.CMUL) {
        if (oracle_checked(left, right, op.code, &regs[op.dst])) {
            oracle_coverage.checked_overflows++;
            errors.appendf("FAULT line %d: arithmetic overflow\n", line);
            return true;
        }
        return false;
    }
    regs[op.dst] = oracle_wrap(left, right, op.code);
    return false;
}

fn OwnershipCase oracle_result(DString output, DString errors, int status) {
    if (status == 0) {
        oracle_coverage.successes++;
    } else {
        oracle_coverage.faults++;
    }
    return { "", output.str_view(), errors.str_view(), status, false };
}

fn OwnershipCase oracle_reference(OracleProgram* program) {
    long[16] regs = {};
    char[64] cells = {};
    OracleMed[3] meds = {};
    meds[0] = { .size = 64, .valid = true };
    DString output = dstring::temp(); DString errors = dstring::temp();
    int pc = 0; int steps = 0;
    while (pc < program.len) {
        assert(steps < ORACLE_STEP_LIMIT);
        steps++;
        OracleOp op = program.ops[pc];
        oracle_coverage.opcodes[(int)op.code]++;
        int line = pc + 3;
        if (op.code == OracleOpcode.VIEW) {
            if (oracle_view(op, regs[..], meds[..], &errors, line)) {
                return oracle_result(output, errors, 1);
            }
            pc++;
            continue;
        }
        if (op.code == OracleOpcode.LOAD || op.code == OracleOpcode.STORE) {
            if (oracle_memory(op, regs[..], meds[..], cells[..], &errors, line)) {
                return oracle_result(output, errors, 1);
            }
            pc++;
            continue;
        }
        if (op.code == OracleOpcode.RET) return oracle_result(output, errors, 0);
        switch (op.code) {
            case OracleOpcode.MOV_IMM:
                regs[op.dst] = op.literal;
            case OracleOpcode.MOV_REG:
                regs[op.dst] = regs[op.left];
            case OracleOpcode.INC:
                regs[op.dst] = oracle_wrap(regs[op.dst], 1, OracleOpcode.ADD);
            case OracleOpcode.DEC:
                regs[op.dst] = oracle_wrap(regs[op.dst], 1, OracleOpcode.SUB);
            case OracleOpcode.CINC:
                if (oracle_checked(regs[op.dst], 1, OracleOpcode.CADD, &regs[op.dst])) {
                    oracle_coverage.checked_overflows++;
                    errors.appendf("FAULT line %d: arithmetic overflow\n", line);
                    return oracle_result(output, errors, 1);
                }
            case OracleOpcode.CDEC:
                if (oracle_checked(regs[op.dst], 1, OracleOpcode.CSUB, &regs[op.dst])) {
                    oracle_coverage.checked_overflows++;
                    errors.appendf("FAULT line %d: arithmetic overflow\n", line);
                    return oracle_result(output, errors, 1);
                }
            case OracleOpcode.PRINT:
                output.appendf("%d\n", regs[op.left]);
            case OracleOpcode.BRZ:
                bool taken = regs[op.left] == 0;
                oracle_cover_branch(taken, op.target < pc);
                if (taken) pc = op.target;
            case OracleOpcode.BRNZ:
                bool taken = regs[op.left] != 0;
                oracle_cover_branch(taken, op.target < pc);
                if (taken) pc = op.target;
            case OracleOpcode.LABEL:
                break;
            default:
                if (oracle_apply(op, regs[..], &errors, line)) {
                    return oracle_result(output, errors, 1);
                }
        }
        pc++;
    }
    return oracle_result(output, errors, 0);
}

fn bool oracle_program_fails(OracleProgram* program) {
    OwnershipCase expected = oracle_reference(program);
    expected.source = oracle_source(program);
    int? result = oracle_view_mutation
        ? run_ownership_view_mutation(expected, "oracle-view-mutation.rza")
        : run_ownership_case(expected, "oracle-shrink.rza", false);
    if (catch result) {
        io::eprintn("oracle harness error");
        return true;
    }
    if (result != 0) io::eprintfn("oracle predicate status=%d", result);
    return result != 0;
}

fn bool oracle_world_fails(OracleWorld world) {
    OracleProgram program = oracle_generate(world);
    return oracle_program_fails(&program);
}

fn int? oracle_run_case(ulong seed) {
    OracleWorld world = oracle_world(seed);
    if (!oracle_world_fails(world)) return 0;
    OracleWorld reduced = oracle_shrink(world, &oracle_world_fails);
    io::eprintfn("oracle seed=%d prefix=%d forward=%d loop=%d suffix=%d trips=%d",
        reduced.seed, reduced.prefix_ops, reduced.forward_ops, reduced.loop_ops,
        reduced.suffix_ops, reduced.loop_trips);
    OracleProgram program = oracle_generate(reduced);
    io::eprintn(oracle_source(&program));
    return 1;
}

fn int oracle_binary_edge(OracleOpcode code, long left, long right) {
    OracleProgram program = {};
    oracle_push(&program, {
        .code = OracleOpcode.MOV_IMM, .dst = 0, .literal = left, .literal_rhs = true,
    });
    oracle_push(&program, {
        .code = OracleOpcode.MOV_IMM, .dst = 1, .literal = right, .literal_rhs = true,
    });
    oracle_push(&program, { .code = code, .dst = 2, .left = 0, .right = 1 });
    oracle_push(&program, { .code = OracleOpcode.PRINT, .left = 2 });
    oracle_push(&program, { .code = OracleOpcode.RET });
    if (!oracle_program_fails(&program)) return 0;
    io::eprintn(oracle_source(&program));
    return 1;
}

fn int oracle_unary_edge(OracleOpcode code, long value) {
    OracleProgram program = {};
    oracle_push(&program, {
        .code = OracleOpcode.MOV_IMM, .dst = 0, .literal = value, .literal_rhs = true,
    });
    oracle_push(&program, { .code = code, .dst = 0, .left = 0 });
    oracle_push(&program, { .code = OracleOpcode.PRINT, .left = 0 });
    oracle_push(&program, { .code = OracleOpcode.RET });
    if (!oracle_program_fails(&program)) return 0;
    io::eprintn(oracle_source(&program));
    return 1;
}

fn int? oracle_view_mutation_shrink() {
    OracleWorld world = {
        .seed = 0xB10E,
        .prefix_ops = 4,
        .forward_ops = 2,
        .loop_ops = 2,
        .suffix_ops = 4,
        .loop_trips = 3,
        .forward_branch = true,
        .backward_loop = true,
        .view_scenario = ViewScenario.INVALID,
    };
    oracle_view_mutation = true;
    defer oracle_view_mutation = false;
    if (!expect(oracle_world_fails(world), "view mutation escapes the oracle")) return 1;
    OracleWorld reduced = oracle_shrink(world, &oracle_world_fails);
    OracleProgram program = oracle_generate(reduced);
    if (!expect(reduced.view_scenario == ViewScenario.INVALID && program.len == 3
            && !reduced.forward_branch && !reduced.backward_loop,
            "view mutation shrinks to mov, view and ret")) return 1;
    return 0;
}

fn int? oracle_views_run() {
    for (int scenario = 1; scenario <= 5; scenario++) {
        OracleWorld world = oracle_world((ulong)(0x7100 + scenario));
        world.prefix_ops = 0;
        world.forward_ops = 0;
        world.loop_ops = 0;
        world.suffix_ops = 0;
        world.forward_branch = false;
        world.backward_loop = false;
        world.view_scenario = (ViewScenario)scenario;
        if (!oracle_world_fails(world)) continue;
        io::eprintfn("view oracle scenario=%d", scenario);
        OracleProgram program = oracle_generate(world);
        io::eprintn(oracle_source(&program));
        return 1;
    }
    if (oracle_view_mutation_shrink()! != 0) return 1;
    return 0;
}

fn int? oracle_edges_run() {
    long min = -9223372036854775807 - 1;
    long max = 9223372036854775807;
    if (oracle_binary_edge(OracleOpcode.DIV, min, -1) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.MOD, 1, 0) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.DIV, min, -2) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.MOD, min, -2) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.SHL, 1, 64) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.SHL, 1, -1) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.SHR, min, 63) != 0) return 1;
    if (oracle_binary_edge(OracleOpcode.USHR, min, 63) != 0) return 1;
    if (oracle_unary_edge(OracleOpcode.CINC, max) != 0) return 1;
    if (oracle_unary_edge(OracleOpcode.CDEC, min) != 0) return 1;
    return 0;
}

fn int oracle_main() {
    defer (void)cleanup_temp_dir();
    int? status = oracle_run();
    if (catch status) {
        io::eprintn("EXECUTION_ORACLE FAILED");
        return 1;
    }
    return status;
}

fn int? oracle_run() {
    reset_temp_dir()!;
    oracle_coverage_reset();
    if (oracle_shrink_selftest()! != 0) return 1;
    for (ulong seed = 1; seed <= 64; seed++) {
        if (oracle_run_case(seed)! != 0) return 1;
    }
    if (oracle_edges_run()! != 0) return 1;
    if (oracle_views_run()! != 0) return 1;
    if (proc_oracle_run()! != 0) return 1;
    if (cascade_oracle_run()! != 0) return 1;
    if (!oracle_coverage_ok()) return 1;
    oracle_coverage_print();
    io::printn("EXECUTION_ORACLE OK (183 programs)");
    return 0;
}
