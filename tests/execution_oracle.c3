module rza_tests;

import libc;
import std::core::dstring;
import std::io;

const int ORACLE_OPS_MAX = 64;
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
    SLT,
    AND,
    LOAD,
    STORE,
    PRINT,
    INC,
    DEC,
    LABEL,
    BRZ,
    BRNZ,
    RET,
}

struct OracleOp {
    OracleOpcode code;
    int dst;
    int left;
    int right;
    int target;
    long literal;
    bool literal_rhs;
}

struct OracleProgram {
    OracleOp[ORACLE_OPS_MAX] ops;
    int len;
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
    int choice = rng.below(15);
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
        case 8: op.code = OracleOpcode.SLT;
        case 9:
            op.code = OracleOpcode.AND;
            op.literal = 56;
            op.literal_rhs = true;
        case 10: op.code = OracleOpcode.LOAD;
        case 11: op.code = OracleOpcode.STORE;
        case 12: op.code = OracleOpcode.PRINT;
        case 13: op.code = OracleOpcode.INC;
        default: op.code = OracleOpcode.DEC;
    }
    oracle_push(program, op);
}

fn void oracle_random_ops(OracleProgram* program, OracleRng* rng, int count) {
    assert(count >= 0);
    for (int i = 0; i < count; i++) oracle_random_op(program, rng);
}

fn OracleProgram oracle_generate(OracleWorld world) {
    OracleProgram program = {};
    OracleRng rng = { world.seed };
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
            case OracleOpcode.SLT: case OracleOpcode.AND:
                String[] names = { "add", "sub", "mul", "cadd", "csub", "cmul", "slt", "and" };
                int index = (int)op.code - (int)OracleOpcode.ADD;
                source.appendf("%s %%r%d, %%r%d, %s\n", names[index],
                    op.dst, op.left, oracle_rhs(op));
            case OracleOpcode.LOAD:
                source.appendf("load %%r%d, [cells_m + %%r%d]\n", op.dst, op.right);
            case OracleOpcode.STORE:
                source.appendf("store [cells_m + %%r%d], %%r%d\n", op.right, op.left);
            case OracleOpcode.PRINT:
                source.appendf("print %%r%d\n", op.left);
            case OracleOpcode.INC:
                source.appendf("inc %%r%d\n", op.dst);
            case OracleOpcode.DEC:
                source.appendf("dec %%r%d\n", op.dst);
            case OracleOpcode.LABEL:
                source.appendf("l%d:\n", i);
            case OracleOpcode.BRZ:
                source.appendf("brz %%r%d, l%d\n", op.left, op.target);
            case OracleOpcode.BRNZ:
                source.appendf("brnz %%r%d, l%d\n", op.left, op.target);
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

fn bool oracle_memory(OracleOp op, long[] regs, char[] cells, DString* errors, int line) {
    long offset = regs[op.right];
    if (offset < 0 || offset > 56) {
        oracle_coverage.bounds_faults++;
        errors.appendf("FAULT line %d: out of bounds cells_m\n", line);
        return true;
    }
    if (op.code == OracleOpcode.LOAD) {
        libc::memcpy(&regs[op.dst], &cells[(sz)offset], 8);
    } else {
        libc::memcpy(&cells[(sz)offset], &regs[op.left], 8);
    }
    return false;
}

fn bool oracle_apply(OracleOp op, long[] regs, DString* errors, int line) {
    long left = regs[op.left];
    long right = op.literal_rhs ? op.literal : regs[op.right];
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
    DString output = dstring::temp();
    DString errors = dstring::temp();
    int pc = 0;
    int steps = 0;
    while (pc < program.len) {
        assert(steps < ORACLE_STEP_LIMIT);
        steps++;
        OracleOp op = program.ops[pc];
        oracle_coverage.opcodes[(int)op.code]++;
        int line = pc + 3;
        if (op.code == OracleOpcode.LOAD || op.code == OracleOpcode.STORE) {
            if (oracle_memory(op, regs[..], cells[..], &errors, line)) {
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

fn bool oracle_world_fails(OracleWorld world) {
    OracleProgram program = oracle_generate(world);
    OwnershipCase expected = oracle_reference(&program);
    expected.source = oracle_source(&program);
    int? result = run_ownership_case(expected, "oracle-shrink.rza", false);
    if (catch result) {
        io::eprintn("oracle harness error");
        return true;
    }
    if (result != 0) io::eprintfn("oracle predicate status=%d", result);
    return result != 0;
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
    if (proc_oracle_run()! != 0) return 1;
    if (cascade_oracle_run()! != 0) return 1;
    if (!oracle_coverage_ok()) return 1;
    oracle_coverage_print();
    io::printn("EXECUTION_ORACLE OK (164 programs)");
    return 0;
}
