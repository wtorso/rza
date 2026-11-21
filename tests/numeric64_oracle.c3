module rza_tests;

import std::core::dstring;
import std::io;

const int NUMERIC64_PROGRAM_OPS_MAX = 16;

struct Numeric64Instruction {
    Numeric64Op op;
    Numeric64Type type;
    int dst;
    int left;
    int right;
    long value;
    bool immediate_rhs;
    bool dynamic_offset;
    bool negative_hex;
}

struct Numeric64Program {
    Numeric64Instruction[NUMERIC64_PROGRAM_OPS_MAX] ops;
    int len;
}

struct Numeric64Expected {
    DString output;
    DString errors;
    int status;
}

union Numeric64NativeWord {
    ulong value;
    char[8] bytes;
}

fn void numeric64_push(Numeric64Program* program, Numeric64Instruction ins) {
    assert(program.len >= 0 && program.len < NUMERIC64_PROGRAM_OPS_MAX);
    program.ops[program.len] = ins;
    program.len++;
}

fn void numeric64_push_legacy(Numeric64Program* program, int dst, long value) {
    numeric64_push(program, {
        .op = Numeric64Op.LEGACY_MOV, .dst = dst, .value = value,
    });
}

fn Numeric64Program numeric64_make_program(Numeric64Op op, Numeric64Type type,
        long left, long right, bool immediate, int fault_mode) {
    Numeric64Program program = {};
    numeric64_push_legacy(&program, 0, left);
    numeric64_push_legacy(&program, 1, right);
    if (op == Numeric64Op.LOAD) {
        numeric64_push(&program, {
            .op = Numeric64Op.SETUP_STORE, .type = type, .left = 0,
        });
    }
    if (fault_mode == 2) numeric64_push(&program, { .op = Numeric64Op.DECAY });
    Numeric64Instruction target = {
        .op = op, .type = type, .dst = 2, .left = 0, .right = 1,
        .value = right, .immediate_rhs = immediate,
        .dynamic_offset = fault_mode == 1,
    };
    if (op == Numeric64Op.MOV_IMM) target.value = left;
    if (op == Numeric64Op.INC || op == Numeric64Op.DEC ||
            op == Numeric64Op.CINC || op == Numeric64Op.CDEC) {
        target.dst = 0;
    }
    numeric64_push(&program, target);
    if (op == Numeric64Op.STORE) {
        numeric64_push(&program, {
            .op = Numeric64Op.LOAD, .type = type, .dst = 2, .right = 1,
            .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric64_push(&program, {
        .op = Numeric64Op.PRINT, .left = target.dst,
    });
    numeric64_push(&program, { .op = Numeric64Op.RET });
    return program;
}

fn int numeric64_fault_line(int index) {
    assert(index >= 0 && index < NUMERIC64_PROGRAM_OPS_MAX);
    return index + 4;
}

fn bool numeric64_memory_fault(Numeric64Instruction ins, long offset,
        bool alive, DString* errors, int line) {
    if (!alive) {
        errors.appendf("FAULT line %d: dead mediator raw_m\n", line);
        numeric64_cover_fault(ins.op, ins.type, Numeric64Fault.DEAD);
        return true;
    }
    if (offset < 0 || offset >= 1) {
        errors.appendf("FAULT line %d: out of bounds raw_m\n", line);
        numeric64_cover_fault(ins.op, ins.type, Numeric64Fault.BOUNDS);
        return true;
    }
    return false;
}

fn bool numeric64_immediate_form(Numeric64Instruction ins) {
    if (ins.op == Numeric64Op.MOV_IMM) return true;
    if (ins.op == Numeric64Op.MOV_REG || ins.op == Numeric64Op.INC ||
            ins.op == Numeric64Op.DEC || ins.op == Numeric64Op.CINC ||
            ins.op == Numeric64Op.CDEC) return false;
    if (ins.op == Numeric64Op.LOAD || ins.op == Numeric64Op.STORE) {
        return !ins.dynamic_offset;
    }
    return ins.immediate_rhs;
}

fn bool numeric64_dirty_input(Numeric64Instruction ins, long left, long right) {
    if (ins.op == Numeric64Op.MOV_IMM) return false;
    if (((ulong)left & 0x8000000000000000) != 0) return true;
    bool shift = ins.op == Numeric64Op.SHL || ins.op == Numeric64Op.SHR ||
        ins.op == Numeric64Op.USHR;
    bool unary = ins.op == Numeric64Op.INC || ins.op == Numeric64Op.DEC ||
        ins.op == Numeric64Op.CINC || ins.op == Numeric64Op.CDEC;
    if (ins.op == Numeric64Op.MOV_REG || ins.op == Numeric64Op.LOAD ||
            ins.op == Numeric64Op.STORE || shift || unary || ins.immediate_rhs) {
        return false;
    }
    return ((ulong)right & 0x8000000000000000) != 0;
}

fn void numeric64_cover_execution(Numeric64Instruction ins, long left, long right) {
    numeric64_cover_success(ins.op, ins.type, numeric64_immediate_form(ins),
        numeric64_dirty_input(ins, left, right));
}

fn void numeric64_setup_cell(Numeric64Type type, long value, char[] cell) {
    assert(cell.len == 8);
    Numeric64NativeWord setup = { .value = (ulong)value };
    for (int byte = 0; byte < 8; byte++) cell[byte] = setup.bytes[byte];
}

fn void numeric64_access_cell(Numeric64Instruction ins, long offset,
        long left, long* result, char[] cell) {
    assert(cell.len == 8 && offset >= 0 && offset < 1);
    sz index = (sz)offset;
    Numeric64NativeWord converted;
    if (ins.op == Numeric64Op.LOAD) {
        for (int byte = 0; byte < 8; byte++) converted.bytes[byte] = cell[index + byte];
        *result = numeric64_normalize(ins.type, (ulong)converted.value);
        return;
    }
    converted.value = (ulong)left;
    for (int byte = 0; byte < 8; byte++) cell[index + byte] = converted.bytes[byte];
}

fn Numeric64Expected numeric64_reference(Numeric64Program* program) {
    long[16] regs = {};
    char[8] cell = {};
    bool alive = true;
    DString output = dstring::temp();
    DString errors = dstring::temp();
    for (int index = 0; index < program.len; index++) {
        Numeric64Instruction ins = program.ops[index];
        int line = numeric64_fault_line(index);
        if (ins.op == Numeric64Op.RET) {
            numeric64_coverage.valid++;
            return { output, errors, 0 };
        }
        if (ins.op == Numeric64Op.DECAY) {
            alive = false;
            continue;
        }
        if (ins.op == Numeric64Op.PRINT) {
            output.appendf("%d\n", regs[ins.left]);
            continue;
        }
        if (ins.op == Numeric64Op.LEGACY_MOV) {
            regs[ins.dst] = ins.value;
            continue;
        }
        if (ins.op == Numeric64Op.SETUP_STORE) {
            numeric64_setup_cell(ins.type, regs[ins.left], cell[..]);
            continue;
        }
        long left = regs[ins.left];
        long right = ins.immediate_rhs ? ins.value : regs[ins.right];
        if (ins.op == Numeric64Op.LOAD || ins.op == Numeric64Op.STORE) {
            long offset = ins.dynamic_offset ? regs[ins.right] : 0;
            if (numeric64_memory_fault(ins, offset, alive, &errors, line)) {
                return { output, errors, 1 };
            }
            numeric64_access_cell(ins, offset, left, &regs[ins.dst], cell[..]);
            numeric64_cover_execution(ins, left, right);
            continue;
        }
        if (ins.op == Numeric64Op.MOV_IMM) {
            regs[ins.dst] = numeric64_normalize(ins.type, (ulong)ins.value);
        } else if (ins.op == Numeric64Op.MOV_REG) {
            regs[ins.dst] = numeric64_normalize(ins.type, (ulong)left);
        } else {
            bool shift = ins.op == Numeric64Op.SHL || ins.op == Numeric64Op.SHR ||
                ins.op == Numeric64Op.USHR;
            if (shift && right == 65) {
                numeric64_cover_shift65(numeric64_immediate_form(ins));
            }
            Numeric64Fault failure;
            long value = numeric64_evaluate(ins.op, ins.type, left, right, &failure);
            if (failure != Numeric64Fault.NONE) {
                String reason = failure == Numeric64Fault.ARITHMETIC ? "arithmetic overflow"
                    : failure == Numeric64Fault.DIVISION ? "division" : "shift";
                errors.appendf("FAULT line %d: %s\n", line, reason);
                numeric64_cover_fault(ins.op, ins.type, failure);
                return { output, errors, 1 };
            }
            regs[ins.dst] = value;
        }
        numeric64_cover_execution(ins, left, right);
    }
    unreachable("numeric64 reference requires ret");
}

fn String numeric64_type_name(Numeric64Type type) {
    return type == Numeric64Type.I64 ? "i64" : "u64";
}

fn String numeric64_op_name(Numeric64Op op) {
    switch (op) {
        case Numeric64Op.MOV_IMM: case Numeric64Op.MOV_REG: return "mov";
        case Numeric64Op.LOAD: return "load";
        case Numeric64Op.STORE: return "store";
        case Numeric64Op.ADD: return "add";
        case Numeric64Op.SUB: return "sub";
        case Numeric64Op.MUL: return "mul";
        case Numeric64Op.INC: return "inc";
        case Numeric64Op.DEC: return "dec";
        case Numeric64Op.CADD: return "cadd";
        case Numeric64Op.CSUB: return "csub";
        case Numeric64Op.CMUL: return "cmul";
        case Numeric64Op.CINC: return "cinc";
        case Numeric64Op.CDEC: return "cdec";
        case Numeric64Op.AND: return "and";
        case Numeric64Op.OR: return "or";
        case Numeric64Op.XOR: return "xor";
        case Numeric64Op.SLT: return "slt";
        case Numeric64Op.ULT: return "ult";
        case Numeric64Op.DIV: return "div";
        case Numeric64Op.MOD: return "mod";
        case Numeric64Op.SHL: return "shl";
        case Numeric64Op.SHR: return "shr";
        case Numeric64Op.USHR: return "ushr";
        default: unreachable("not a typed numeric64 opcode");
    }
}

fn void numeric64_emit_typed(DString* source, Numeric64Instruction ins) {
    String op = numeric64_op_name(ins.op);
    String type = numeric64_type_name(ins.type);
    if (ins.op == Numeric64Op.MOV_IMM) {
        source.appendf("mov.%s %%r%d, 0x%016x\n", type, ins.dst,
            (ulong)ins.value);
        return;
    }
    if (ins.op == Numeric64Op.MOV_REG) {
        source.appendf("mov.%s %%r%d, %%r%d\n", type, ins.dst, ins.left);
        return;
    }
    if (ins.op == Numeric64Op.LOAD || ins.op == Numeric64Op.STORE) {
        DString offset = dstring::temp();
        if (ins.dynamic_offset) {
            offset.appendf("%%r%d", ins.right);
        } else {
            offset.append("0");
        }
        if (ins.op == Numeric64Op.LOAD) {
            source.appendf("load.%s %%r%d, [raw_m + %s]\n", type, ins.dst,
                offset.str_view());
        } else {
            source.appendf("store.%s [raw_m + %s], %%r%d\n", type,
                offset.str_view(), ins.left);
        }
        return;
    }
    if (ins.op == Numeric64Op.INC || ins.op == Numeric64Op.DEC ||
            ins.op == Numeric64Op.CINC || ins.op == Numeric64Op.CDEC) {
        source.appendf("%s.%s %%r%d\n", op, type, ins.dst);
        return;
    }
    source.appendf("%s.%s %%r%d, %%r%d, ", op, type, ins.dst, ins.left);
    if (!ins.immediate_rhs) {
        source.appendf("%%r%d\n", ins.right);
        return;
    }
    bool shift = ins.op == Numeric64Op.SHL || ins.op == Numeric64Op.SHR ||
        ins.op == Numeric64Op.USHR;
    if (shift && ins.negative_hex && ins.value < 0) {
        source.appendf("-0x%x\n", -(ulong)ins.value);
    } else if (shift) {
        source.appendf("%d\n", ins.value);
    } else {
        source.appendf("0x%016x\n", (ulong)ins.value);
    }
}

fn String numeric64_source(Numeric64Program* program) {
    DString source = dstring::temp("cav main, field\nres raw, main, 8\n"
        "med raw_m, raw, main\n");
    for (int index = 0; index < program.len; index++) {
        Numeric64Instruction ins = program.ops[index];
        switch (ins.op) {
            case Numeric64Op.LEGACY_MOV:
                source.appendf("mov %%r%d, %d\n", ins.dst, ins.value);
            case Numeric64Op.SETUP_STORE:
                source.appendf("store.%s [raw_m + 0], %%r%d\n",
                    numeric64_type_name(ins.type), ins.left);
            case Numeric64Op.PRINT:
                source.appendf("print %%r%d\n", ins.left);
            case Numeric64Op.DECAY:
                source.append("decay main\n");
            case Numeric64Op.RET:
                source.append("ret\n");
            default:
                numeric64_emit_typed(&source, ins);
        }
    }
    return source.str_view();
}

fn int numeric64_valid_forms(Numeric64Op op) {
    if (op == Numeric64Op.MOV_IMM || op == Numeric64Op.MOV_REG ||
            op == Numeric64Op.INC || op == Numeric64Op.DEC ||
            op == Numeric64Op.CINC || op == Numeric64Op.CDEC) return 1;
    return 2;
}

fn Numeric64Instruction numeric64_valid_operation(int slot) {
    assert(slot >= 0 && slot < 78);
    Numeric64Instruction selected = { .dst = 2, .left = 0, .right = 1 };
    int cell = 0;
    bool found = false;
    for (int raw_op = 0; raw_op < NUMERIC64_OP_COUNT; raw_op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric64Op op = (Numeric64Op)raw_op;
            Numeric64Type type = (Numeric64Type)raw_type;
            if (!numeric64_legal(op, type)) continue;
            int forms = numeric64_valid_forms(op);
            for (int form = 0; form < forms; form++) {
                if (cell == slot) {
                    selected.op = op;
                    selected.type = type;
                    selected.immediate_rhs = forms == 2 ? form == 0
                        : op == Numeric64Op.MOV_IMM;
                    selected.dynamic_offset = (op == Numeric64Op.LOAD ||
                        op == Numeric64Op.STORE) && form == 1;
                    if (op == Numeric64Op.MOV_REG) selected.dst = 0;
                    found = true;
                }
                cell++;
            }
        }
    }
    assert(found && cell == 78);
    return selected;
}

fn void numeric64_valid_values(Numeric64Instruction* ins, int slot,
        long* left, long* right) {
    *left = slot % 3 == 0 ? -1 : -9223372036854775808;
    *right = slot % 2 == 0 ? -1 : (long)((ulong)(slot * 11) & 0x7fff);
    if (ins.op == Numeric64Op.MOV_REG) *left = -9223372036854775808;
    if (ins.immediate_rhs && ins.op != Numeric64Op.SHL && ins.op != Numeric64Op.SHR &&
            ins.op != Numeric64Op.USHR) {
        *left = -9223372036854775808;
    }
    if (ins.op == Numeric64Op.CADD) {
        *left = ins.type == Numeric64Type.I64 ? -9223372036854775808 : -1;
        *right = ins.type == Numeric64Type.I64 ? 1 : 0;
    }
    if (ins.op == Numeric64Op.CMUL) {
        *left = -1;
        *right = ins.type == Numeric64Type.I64 ? -1 : 0;
    }
    if (ins.op == Numeric64Op.CSUB) {
        *left = -1;
        *right = ins.type == Numeric64Type.I64 ? -1 : -2;
    }
    if (ins.op == Numeric64Op.CINC) *left = -9223372036854775808;
    if (ins.op == Numeric64Op.CDEC) *left = -1;
    if (ins.op == Numeric64Op.DIV || ins.op == Numeric64Op.MOD) {
        *left = ins.op == Numeric64Op.MOD && ins.type == Numeric64Type.U64
            ? -1 : -9223372036854775808;
        *right = 2;
    }
    bool shift = ins.op == Numeric64Op.SHL || ins.op == Numeric64Op.SHR ||
        ins.op == Numeric64Op.USHR;
    if (shift) {
        *left = -9223372036854775808;
        *right = 1;
    }
    if (ins.op == Numeric64Op.LOAD || ins.op == Numeric64Op.STORE) {
        *left = -9223372036854775808;
        *right = 0;
    }
    ins.value = *right;
    if (ins.op == Numeric64Op.MOV_IMM) ins.value = *left;
}

fn void numeric64_valid_slot(Numeric64Program* program, int slot) {
    Numeric64Instruction target = numeric64_valid_operation(slot);
    long left;
    long right;
    numeric64_valid_values(&target, slot, &left, &right);
    numeric64_push_legacy(program, 0, left);
    numeric64_push_legacy(program, 1, right);
    if (target.op == Numeric64Op.LOAD) {
        numeric64_push(program, {
            .op = Numeric64Op.SETUP_STORE, .type = target.type, .left = 0,
        });
    }
    if (target.op == Numeric64Op.INC || target.op == Numeric64Op.DEC ||
            target.op == Numeric64Op.CINC || target.op == Numeric64Op.CDEC) {
        target.dst = 0;
    }
    numeric64_push(program, target);
    if (target.op == Numeric64Op.STORE) {
        numeric64_push(program, {
            .op = Numeric64Op.LOAD, .type = target.type, .dst = 2,
            .left = 0, .right = 1, .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric64_push(program, { .op = Numeric64Op.PRINT, .left = target.dst });
}

fn Numeric64Program numeric64_valid_program(int index) {
    assert(index >= 0 && index < 64);
    Numeric64Program program = {};
    int slot = index * 2;
    numeric64_valid_slot(&program, slot % 78);
    numeric64_valid_slot(&program, (slot + 1) % 78);
    numeric64_push(&program, { .op = Numeric64Op.RET });
    return program;
}

fn Numeric64Program numeric64_fault_checked(int index) {
    Numeric64Op[] ops = {
        Numeric64Op.CADD, Numeric64Op.CADD, Numeric64Op.CSUB, Numeric64Op.CSUB,
        Numeric64Op.CMUL, Numeric64Op.CMUL, Numeric64Op.CADD, Numeric64Op.CSUB,
        Numeric64Op.CMUL, Numeric64Op.CINC, Numeric64Op.CDEC,
        Numeric64Op.CINC, Numeric64Op.CDEC,
    };
    Numeric64Type[] types = {
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.I64,
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.U64, Numeric64Type.U64,
        Numeric64Type.U64, Numeric64Type.I64, Numeric64Type.I64,
        Numeric64Type.U64, Numeric64Type.U64,
    };
    long[] left = {
        9223372036854775807, -9223372036854775808,
        9223372036854775807, -9223372036854775808, 4611686018427387904,
        -9223372036854775808, -1, 0, -1,
        9223372036854775807, -9223372036854775808, -1, 0,
    };
    long[] right = { 1, -1, -1, 1, 2, 2, 1, 1, 2, 0, 0, 0, 0 };
    assert(index >= 0 && index < 13);
    return numeric64_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric64Program numeric64_fault_division(int index) {
    Numeric64Op[] ops = {
        Numeric64Op.DIV, Numeric64Op.DIV, Numeric64Op.MOD,
        Numeric64Op.MOD, Numeric64Op.DIV, Numeric64Op.MOD,
    };
    Numeric64Type[] types = {
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.I64,
        Numeric64Type.I64, Numeric64Type.U64, Numeric64Type.U64,
    };
    long[] left = { 1, -9223372036854775808, 1, -9223372036854775808, 1, 1 };
    long[] right = { 0, -1, 0, -1, 0, 0 };
    assert(index >= 0 && index < 6);
    return numeric64_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric64Program numeric64_fault_shift(int index) {
    Numeric64Op[] ops = {
        Numeric64Op.SHL, Numeric64Op.SHL, Numeric64Op.SHL, Numeric64Op.SHL,
        Numeric64Op.SHR, Numeric64Op.SHR, Numeric64Op.USHR, Numeric64Op.USHR,
        Numeric64Op.USHR, Numeric64Op.USHR,
    };
    Numeric64Type[] types = {
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.U64, Numeric64Type.U64,
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.I64,
        Numeric64Type.U64, Numeric64Type.U64,
    };
    assert(index >= 0 && index < 10);
    long right = index % 2 == 0 ? -1 : 64;
    Numeric64Program program = numeric64_make_program(ops[index], types[index],
        1, right, true, 0);
    program.ops[2].negative_hex = index % 2 == 0;
    return program;
}

fn Numeric64Program numeric64_fault_memory(int index) {
    Numeric64Op op = index < 4 ? Numeric64Op.LOAD : Numeric64Op.STORE;
    Numeric64Type[] types = {
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.U64, Numeric64Type.U64,
        Numeric64Type.I64, Numeric64Type.I64, Numeric64Type.U64, Numeric64Type.U64,
    };
    assert(index >= 0 && index < 8);
    int mode = index % 2 == 0 ? 1 : 2;
    return numeric64_make_program(op, types[index], -9223372036854775808, 7, false, mode);
}

fn Numeric64Program numeric64_fault_program(int index) {
    if (index < 13) return numeric64_fault_checked(index);
    if (index < 19) return numeric64_fault_division(index - 13);
    if (index < 29) return numeric64_fault_shift(index - 19);
    return numeric64_fault_memory(index - 29);
}

struct Numeric64Rng {
    ulong state;
}

fn ulong Numeric64Rng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn void numeric64_randomize_fault(Numeric64Program* program, ulong seed) {
    Numeric64Rng rng = { seed ^ 0x9e3779b97f4a7c15 };
    for (int index = 0; index < program.len; index++) {
        Numeric64Instruction* target = &program.ops[index];
        if (target.op >= Numeric64Op.LEGACY_MOV) continue;
        bool shift = target.op == Numeric64Op.SHL || target.op == Numeric64Op.SHR ||
            target.op == Numeric64Op.USHR;
        if (shift && seed % 3 != 0) {
            program.ops[1].value = 65;
            target.value = 65;
            target.immediate_rhs = seed % 2 == 0;
        } else if (rng.next() % 2 == 0) {
            target.immediate_rhs = !target.immediate_rhs;
        }
        break;
    }
}

ulong numeric64_attempt;
int numeric64_mutation;
char[1048576] numeric64_generated_buf;

fn String numeric64_replace(String text, String needle, String replacement,
        bool* changed) {
    DString out = dstring::temp();
    String rest = text;
    *changed = false;
    while (rest.len > 0) {
        sz? found = rest.index_of(needle);
        if (catch found) break;
        out.append_string(rest[:found]);
        out.append_string(replacement);
        rest = rest[found + needle.len..];
        *changed = true;
    }
    out.append_string(rest);
    return out.str_view();
}

fn void numeric64_mutate_generated(String path) {
    if (numeric64_mutation == 0) return;
    char[] data = read_file(path, numeric64_generated_buf[..]) ?? unreachable();
    String from = numeric64_mutation == 1
        ? "rez_u64_from_bits" : "if (rez_i64_cadd(";
    String to = numeric64_mutation == 1
        ? "rez_i32_from_bits" : "if (false && rez_i64_cadd(";
    bool changed;
    String mutated = numeric64_replace((String)data, from, to, &changed);
    if (!changed) return;
    write_file(path, mutated) ?? unreachable();
}

enum Numeric64FailureKind : char {
    NONE,
    EMIT,
    COMPILE,
    RUNTIME,
}

struct Numeric64Failure {
    Numeric64FailureKind kind;
    int expected_status;
    int actual_status;
    DString expected_output;
    DString expected_errors;
    DString actual_output;
    DString actual_errors;
}

fn Numeric64Failure numeric64_failure(Numeric64Program program) {
    Numeric64Expected expected = numeric64_reference(&program);
    Numeric64Failure failure = {
        .expected_status = expected.status,
        .expected_output = dstring::temp(normalize_lines(expected.output.str_view())),
        .expected_errors = dstring::temp(normalize_lines(expected.errors.str_view())),
    };
    String source = numeric64_source(&program);
    assert(numeric64_attempt < 1000000);
    String name = string::tformat("numeric64-%d.rza", numeric64_attempt);
    numeric64_attempt++;
    String path = temp_path(name);
    write_file(path, source) ?? unreachable();
    String generated = string::tformat("%s.c", path);
    ProcessResult emitted = run_simple({
        compiler_path(), path, "--emit-c", "-o", generated,
    }) ?? unreachable();
    if (emitted.status != 0 || emitted.stdout_text.len != 0 ||
            emitted.stderr_text.len != 0) {
        failure.kind = Numeric64FailureKind.EMIT;
        failure.actual_status = emitted.status;
        failure.actual_output = dstring::temp(normalize_lines(emitted.stdout_text));
        failure.actual_errors = dstring::temp(normalize_lines(emitted.stderr_text));
        return failure;
    }
    numeric64_mutate_generated(generated);
    String executable = string::tformat("%s.exe", path);
    ProcessResult compiled = compile_c(generated, executable) ?? unreachable();
    if (compiled.status != 0 || compiled.stderr_text.len != 0) {
        failure.kind = Numeric64FailureKind.COMPILE;
        failure.actual_status = compiled.status;
        failure.actual_output = dstring::temp(normalize_lines(compiled.stdout_text));
        failure.actual_errors = dstring::temp(normalize_lines(compiled.stderr_text));
        return failure;
    }
    ProcessResult runtime = run_program({ executable }) ?? unreachable();
    failure.actual_status = runtime.status;
    failure.actual_output = dstring::temp(normalize_lines(runtime.stdout_text));
    failure.actual_errors = dstring::temp(normalize_lines(runtime.stderr_text));
    bool mismatch = runtime.status != expected.status ||
        failure.actual_output.str_view() != failure.expected_output.str_view() ||
        failure.actual_errors.str_view() != failure.expected_errors.str_view();
    if (mismatch) {
        failure.kind = Numeric64FailureKind.RUNTIME;
        io::eprintfn("numeric64 expected status=%d stdout=%s stderr=%s",
            expected.status, expected.output.str_view(), expected.errors.str_view());
        print_result(runtime);
    }
    return failure;
}

fn bool numeric64_failure_same(Numeric64Program candidate, Numeric64Failure original) {
    Numeric64Failure current = numeric64_failure(candidate);
    return current.kind == original.kind &&
        current.expected_status == original.expected_status &&
        current.actual_status == original.actual_status &&
        current.expected_output.str_view() == original.expected_output.str_view() &&
        current.expected_errors.str_view() == original.expected_errors.str_view() &&
        current.actual_output.str_view() == original.actual_output.str_view() &&
        current.actual_errors.str_view() == original.actual_errors.str_view();
}

fn bool numeric64_program_fails(Numeric64Program program) {
    return numeric64_failure(program).kind != Numeric64FailureKind.NONE;
}

fn Numeric64Program numeric64_remove(Numeric64Program program, int index) {
    assert(index >= 0 && index < program.len);
    for (int i = index + 1; i < program.len; i++) program.ops[i - 1] = program.ops[i];
    program.len--;
    return program;
}

fn Numeric64Program numeric64_shrink(Numeric64Program world) {
    Numeric64Failure original = numeric64_failure(world);
    assert(original.kind != Numeric64FailureKind.NONE);
    Numeric64Program best = world;
    for (int round = 0; round < 16; round++) {
        bool changed = false;
        for (int index = 0; index < best.len; index++) {
            Numeric64Op op = best.ops[index].op;
            if (op == Numeric64Op.PRINT || op == Numeric64Op.RET) continue;
            Numeric64Program candidate = numeric64_remove(best, index);
            if (numeric64_failure_same(candidate, original)) {
                best = candidate;
                changed = true;
            }
        }
        if (!changed) break;
    }
    assert(numeric64_failure_same(best, original));
    return best;
}

fn int numeric64_mutation_selftest() {
    Numeric64Program signed_program = numeric64_fault_shift(0);
    Numeric64Program unsigned_program = numeric64_fault_shift(2);
    String signed_shift = numeric64_source(&signed_program);
    String unsigned_shift = numeric64_source(&unsigned_program);
    if (!expect(signed_shift.contains("shl.i64 %r2, %r0, -0x1") &&
            unsigned_shift.contains("shl.u64 %r2, %r0, -0x1"),
            "negative hex shift source forms")) return 1;
    Numeric64Program load = numeric64_make_program(Numeric64Op.LOAD,
        Numeric64Type.U64, -9223372036854775808, 0, false, 0);
    if (!expect(!numeric64_program_fails(load), "numeric64 load fixture")) return 1;
    numeric64_mutation = 1;
    if (!expect(numeric64_program_fails(load),
            "oracle detects truncated u64 load")) return 1;
    numeric64_mutation = 0;
    Numeric64Program checked = numeric64_make_program(Numeric64Op.CADD,
        Numeric64Type.I64, 9223372036854775807, 1, true, 0);
    if (!expect(!numeric64_program_fails(checked), "numeric64 checked fixture")) return 1;
    numeric64_mutation = 2;
    if (!expect(numeric64_program_fails(checked),
            "oracle detects removed checked-overflow guard")) return 1;
    numeric64_mutation = 0;
    return 0;
}

fn int numeric64_shrink_selftest() {
    Numeric64Program program = {};
    numeric64_push_legacy(&program, 0, -9223372036854775808);
    numeric64_push(&program, {
        .op = Numeric64Op.SETUP_STORE, .type = Numeric64Type.U64, .left = 0,
    });
    numeric64_push_legacy(&program, 1, 1);
    numeric64_push(&program, {
        .op = Numeric64Op.ADD, .type = Numeric64Type.I64, .dst = 1,
        .left = 1, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric64_push(&program, {
        .op = Numeric64Op.LOAD, .type = Numeric64Type.U64, .dst = 2, .left = 0,
    });
    numeric64_push(&program, { .op = Numeric64Op.PRINT, .left = 2 });
    numeric64_push(&program, { .op = Numeric64Op.RET });
    numeric64_mutation = 1;
    if (!expect(numeric64_program_fails(program), "numeric64 shrink fixture")) return 1;
    Numeric64Program reduced = numeric64_shrink(program);
    bool has_add = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric64Op.ADD) has_add = true;
    }
    if (!expect(reduced.len == 5 && !has_add && numeric64_program_fails(reduced),
            "numeric64 shrink removes irrelevant instructions without stale artifacts")) {
        return 1;
    }
    numeric64_mutation = 0;
    return 0;
}

fn int numeric64_shrink_signature_selftest() {
    Numeric64Program original = {};
    numeric64_push_legacy(&original, 0, 9223372036854775807);
    numeric64_push_legacy(&original, 1, 1);
    numeric64_push(&original, {
        .op = Numeric64Op.CADD, .type = Numeric64Type.I64, .dst = 2,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric64_push(&original, {
        .op = Numeric64Op.ADD, .type = Numeric64Type.I64, .dst = 3,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric64_push(&original, { .op = Numeric64Op.PRINT, .left = 2 });
    numeric64_push(&original, { .op = Numeric64Op.PRINT, .left = 3 });
    numeric64_push(&original, { .op = Numeric64Op.RET });
    Numeric64Program replacement = numeric64_remove(original, 3);
    numeric64_mutation = 2;
    if (!expect(numeric64_program_fails(replacement),
            "replacement failure remains a failure")) return 1;
    Numeric64Failure original_failure = numeric64_failure(original);
    if (!expect(!numeric64_failure_same(replacement, original_failure),
            "shrink must not accept a different failure signature")) return 1;
    Numeric64Program reduced = numeric64_shrink(original);
    bool has_add = false;
    bool has_cadd = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric64Op.ADD) has_add = true;
        if (reduced.ops[i].op == Numeric64Op.CADD) has_cadd = true;
    }
    numeric64_mutation = 0;
    if (!expect(has_add && has_cadd, "shrink preserves the original operation mix")) {
        return 1;
    }
    return 0;
}

fn int numeric64_run_program(Numeric64Program program) {
    if (!numeric64_program_fails(program)) return 0;
    Numeric64Program reduced = numeric64_shrink(program);
    io::eprintn(numeric64_source(&reduced));
    return 1;
}

fn int numeric64_oracle_main() {
    defer (void)cleanup_temp_dir();
    reset_temp_dir() ?? unreachable();
    if (numeric64_reference_selftest() != 0) return 1;
    if (numeric64_mutation_selftest() != 0) return 1;
    if (numeric64_shrink_selftest() != 0) return 1;
    if (numeric64_shrink_signature_selftest() != 0) return 1;
    numeric64_coverage_reset();
    for (int index = 0; index < 64; index++) {
        Numeric64Program program = numeric64_valid_program(index);
        ulong faults_before = numeric64_coverage.faults;
        if (numeric64_run_program(program) != 0) return 1;
        if (numeric64_coverage.faults != faults_before) {
            io::eprintfn("numeric64 valid index=%d unexpectedly faulted", index);
            io::eprintn(numeric64_source(&program));
            return 1;
        }
    }
    for (int index = 0; index < 64; index++) {
        Numeric64Program program = numeric64_fault_program(index % 37);
        if (index >= 37) numeric64_randomize_fault(&program, (ulong)index);
        numeric64_direct_attribution = index < 37;
        ulong valid_before = numeric64_coverage.valid;
        if (numeric64_run_program(program) != 0) return 1;
        if (numeric64_coverage.valid != valid_before) {
            io::eprintfn("numeric64 fault index=%d unexpectedly succeeded", index);
            io::eprintn(numeric64_source(&program));
            return 1;
        }
    }
    numeric64_direct_attribution = false;
    numeric64_coverage_print();
    if (!numeric64_coverage_ok()) return 1;
    io::printn("NUMERIC64_ORACLE OK (128 programs)");
    return 0;
}
