module rza_tests;

import std::core::dstring;
import std::io;

const int NUMERIC32_PROGRAM_OPS_MAX = 16;

struct Numeric32Instruction {
    Numeric32Op op;
    Numeric32Type type;
    int dst;
    int left;
    int right;
    long value;
    bool immediate_rhs;
    bool dynamic_offset;
}

struct Numeric32Program {
    Numeric32Instruction[NUMERIC32_PROGRAM_OPS_MAX] ops;
    int len;
}

struct Numeric32Expected {
    DString output;
    DString errors;
    int status;
}

union Numeric32NativeWord {
    uint value;
    char[4] bytes;
}

fn void numeric32_push(Numeric32Program* program, Numeric32Instruction ins) {
    assert(program.len >= 0 && program.len < NUMERIC32_PROGRAM_OPS_MAX);
    program.ops[program.len] = ins;
    program.len++;
}

fn void numeric32_push_legacy(Numeric32Program* program, int dst, long value) {
    numeric32_push(program, {
        .op = Numeric32Op.LEGACY_MOV, .dst = dst, .value = value,
    });
}

fn Numeric32Program numeric32_make_program(Numeric32Op op, Numeric32Type type,
        long left, long right, bool immediate, int fault_mode) {
    Numeric32Program program = {};
    numeric32_push_legacy(&program, 0, left);
    numeric32_push_legacy(&program, 1, right);
    if (op == Numeric32Op.LOAD) {
        numeric32_push(&program, {
            .op = Numeric32Op.SETUP_STORE, .type = type, .left = 0,
        });
    }
    if (fault_mode == 2) numeric32_push(&program, { .op = Numeric32Op.DECAY });
    Numeric32Instruction target = {
        .op = op, .type = type, .dst = 2, .left = 0, .right = 1,
        .value = right, .immediate_rhs = immediate,
        .dynamic_offset = fault_mode == 1,
    };
    if (op == Numeric32Op.MOV_IMM) target.value = left;
    if (op == Numeric32Op.INC || op == Numeric32Op.DEC ||
            op == Numeric32Op.CINC || op == Numeric32Op.CDEC) {
        target.dst = 0;
    }
    numeric32_push(&program, target);
    if (op == Numeric32Op.STORE) {
        numeric32_push(&program, {
            .op = Numeric32Op.LOAD, .type = type, .dst = 2, .right = 1,
            .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric32_push(&program, {
        .op = Numeric32Op.PRINT, .left = target.dst,
    });
    numeric32_push(&program, { .op = Numeric32Op.RET });
    return program;
}

fn int numeric32_fault_line(int index) {
    assert(index >= 0 && index < NUMERIC32_PROGRAM_OPS_MAX);
    return index + 4;
}

fn bool numeric32_memory_fault(Numeric32Instruction ins, long offset,
        bool alive, DString* errors, int line) {
    if (!alive) {
        errors.appendf("FAULT line %d: dead mediator raw_m\n", line);
        numeric32_cover_fault(ins.op, ins.type, Numeric32Fault.DEAD);
        return true;
    }
    if (offset < 0 || offset >= 7) {
        errors.appendf("FAULT line %d: out of bounds raw_m\n", line);
        numeric32_cover_fault(ins.op, ins.type, Numeric32Fault.BOUNDS);
        return true;
    }
    return false;
}

fn bool numeric32_immediate_form(Numeric32Instruction ins) {
    if (ins.op == Numeric32Op.MOV_IMM) return true;
    if (ins.op == Numeric32Op.MOV_REG || ins.op == Numeric32Op.INC ||
            ins.op == Numeric32Op.DEC || ins.op == Numeric32Op.CINC ||
            ins.op == Numeric32Op.CDEC) return false;
    if (ins.op == Numeric32Op.LOAD || ins.op == Numeric32Op.STORE) {
        return !ins.dynamic_offset;
    }
    return ins.immediate_rhs;
}

fn bool numeric32_dirty_input(Numeric32Instruction ins, long left, long right) {
    if (ins.op == Numeric32Op.MOV_IMM) return false;
    if (((ulong)left & ~0xffffffffUL) != 0) return true;
    bool shift = ins.op == Numeric32Op.SHL || ins.op == Numeric32Op.SHR ||
        ins.op == Numeric32Op.USHR;
    bool unary = ins.op == Numeric32Op.INC || ins.op == Numeric32Op.DEC ||
        ins.op == Numeric32Op.CINC || ins.op == Numeric32Op.CDEC;
    if (ins.op == Numeric32Op.MOV_REG || ins.op == Numeric32Op.LOAD ||
            ins.op == Numeric32Op.STORE || shift || unary || ins.immediate_rhs) {
        return false;
    }
    return ((ulong)right & ~0xffffffffUL) != 0;
}

fn void numeric32_cover_execution(Numeric32Instruction ins, long left, long right) {
    numeric32_cover_success(ins.op, ins.type, numeric32_immediate_form(ins),
        numeric32_dirty_input(ins, left, right));
}

fn void numeric32_setup_cell(Numeric32Type type, long value, char[] cell) {
    assert(cell.len == 8);
    Numeric32NativeWord setup = { .value = (uint)((ulong)value & 0xffffffff) };
    for (int byte = 0; byte < 4; byte++) cell[byte] = setup.bytes[byte];
}

fn void numeric32_access_cell(Numeric32Instruction ins, long offset,
        long left, long* result, char[] cell) {
    assert(cell.len == 8 && offset >= 0 && offset < 7);
    sz index = (sz)offset;
    Numeric32NativeWord converted;
    if (ins.op == Numeric32Op.LOAD) {
        for (int byte = 0; byte < 4; byte++) converted.bytes[byte] = cell[index + byte];
        *result = numeric32_normalize(ins.type, (ulong)converted.value);
        return;
    }
    converted.value = (uint)((ulong)left & 0xffffffff);
    for (int byte = 0; byte < 4; byte++) cell[index + byte] = converted.bytes[byte];
}

fn Numeric32Expected numeric32_reference(Numeric32Program* program) {
    long[16] regs = {};
    char[8] cell = {};
    bool alive = true;
    DString output = dstring::temp();
    DString errors = dstring::temp();
    for (int index = 0; index < program.len; index++) {
        Numeric32Instruction ins = program.ops[index];
        int line = numeric32_fault_line(index);
        if (ins.op == Numeric32Op.RET) {
            numeric32_coverage.valid++;
            return { output, errors, 0 };
        }
        if (ins.op == Numeric32Op.DECAY) {
            alive = false;
            continue;
        }
        if (ins.op == Numeric32Op.PRINT) {
            output.appendf("%d\n", regs[ins.left]);
            continue;
        }
        if (ins.op == Numeric32Op.LEGACY_MOV) {
            regs[ins.dst] = ins.value;
            continue;
        }
        if (ins.op == Numeric32Op.SETUP_STORE) {
            numeric32_setup_cell(ins.type, regs[ins.left], cell[..]);
            continue;
        }
        long left = regs[ins.left];
        long right = ins.immediate_rhs ? ins.value : regs[ins.right];
        if (ins.op == Numeric32Op.LOAD || ins.op == Numeric32Op.STORE) {
            long offset = ins.dynamic_offset ? regs[ins.right] : 0;
            if (numeric32_memory_fault(ins, offset, alive, &errors, line)) {
                return { output, errors, 1 };
            }
            numeric32_access_cell(ins, offset, left, &regs[ins.dst], cell[..]);
            numeric32_cover_execution(ins, left, right);
            continue;
        }
        if (ins.op == Numeric32Op.MOV_IMM) {
            regs[ins.dst] = numeric32_normalize(ins.type, (ulong)ins.value);
        } else if (ins.op == Numeric32Op.MOV_REG) {
            regs[ins.dst] = numeric32_normalize(ins.type, (ulong)left);
        } else {
            bool shift = ins.op == Numeric32Op.SHL || ins.op == Numeric32Op.SHR ||
                ins.op == Numeric32Op.USHR;
            if (shift && right == 33) {
                numeric32_cover_shift33(numeric32_immediate_form(ins));
            }
            Numeric32Fault failure;
            long value = numeric32_evaluate(ins.op, ins.type, left, right, &failure);
            if (failure != Numeric32Fault.NONE) {
                String reason = failure == Numeric32Fault.ARITHMETIC ? "arithmetic overflow"
                    : failure == Numeric32Fault.DIVISION ? "division" : "shift";
                errors.appendf("FAULT line %d: %s\n", line, reason);
                numeric32_cover_fault(ins.op, ins.type, failure);
                return { output, errors, 1 };
            }
            regs[ins.dst] = value;
        }
        numeric32_cover_execution(ins, left, right);
    }
    unreachable("numeric32 reference requires ret");
}

fn String numeric32_type_name(Numeric32Type type) {
    return type == Numeric32Type.I32 ? "i32" : "u32";
}

fn String numeric32_op_name(Numeric32Op op) {
    switch (op) {
        case Numeric32Op.MOV_IMM: case Numeric32Op.MOV_REG: return "mov";
        case Numeric32Op.LOAD: return "load";
        case Numeric32Op.STORE: return "store";
        case Numeric32Op.ADD: return "add";
        case Numeric32Op.SUB: return "sub";
        case Numeric32Op.MUL: return "mul";
        case Numeric32Op.INC: return "inc";
        case Numeric32Op.DEC: return "dec";
        case Numeric32Op.CADD: return "cadd";
        case Numeric32Op.CSUB: return "csub";
        case Numeric32Op.CMUL: return "cmul";
        case Numeric32Op.CINC: return "cinc";
        case Numeric32Op.CDEC: return "cdec";
        case Numeric32Op.AND: return "and";
        case Numeric32Op.OR: return "or";
        case Numeric32Op.XOR: return "xor";
        case Numeric32Op.SLT: return "slt";
        case Numeric32Op.ULT: return "ult";
        case Numeric32Op.DIV: return "div";
        case Numeric32Op.MOD: return "mod";
        case Numeric32Op.SHL: return "shl";
        case Numeric32Op.SHR: return "shr";
        case Numeric32Op.USHR: return "ushr";
        default: unreachable("not a typed numeric32 opcode");
    }
}

fn void numeric32_emit_typed(DString* source, Numeric32Instruction ins) {
    String op = numeric32_op_name(ins.op);
    String type = numeric32_type_name(ins.type);
    if (ins.op == Numeric32Op.MOV_IMM) {
        source.appendf("mov.%s %%r%d, 0x%08x\n", type, ins.dst,
            (uint)ins.value & 0xffffffff);
        return;
    }
    if (ins.op == Numeric32Op.MOV_REG) {
        source.appendf("mov.%s %%r%d, %%r%d\n", type, ins.dst, ins.left);
        return;
    }
    if (ins.op == Numeric32Op.LOAD || ins.op == Numeric32Op.STORE) {
        DString offset = dstring::temp();
        if (ins.dynamic_offset) {
            offset.appendf("%%r%d", ins.right);
        } else {
            offset.append("0");
        }
        if (ins.op == Numeric32Op.LOAD) {
            source.appendf("load.%s %%r%d, [raw_m + %s]\n", type, ins.dst,
                offset.str_view());
        } else {
            source.appendf("store.%s [raw_m + %s], %%r%d\n", type,
                offset.str_view(), ins.left);
        }
        return;
    }
    if (ins.op == Numeric32Op.INC || ins.op == Numeric32Op.DEC ||
            ins.op == Numeric32Op.CINC || ins.op == Numeric32Op.CDEC) {
        source.appendf("%s.%s %%r%d\n", op, type, ins.dst);
        return;
    }
    source.appendf("%s.%s %%r%d, %%r%d, ", op, type, ins.dst, ins.left);
    if (!ins.immediate_rhs) {
        source.appendf("%%r%d\n", ins.right);
        return;
    }
    bool shift = ins.op == Numeric32Op.SHL || ins.op == Numeric32Op.SHR ||
        ins.op == Numeric32Op.USHR;
    if (shift) {
        source.appendf("%d\n", ins.value);
    } else {
        source.appendf("0x%08x\n", (uint)ins.value & 0xffffffff);
    }
}

fn String numeric32_source(Numeric32Program* program) {
    DString source = dstring::temp("cav main, field\nres raw, main, 8\n"
        "med raw_m, raw, main\n");
    for (int index = 0; index < program.len; index++) {
        Numeric32Instruction ins = program.ops[index];
        switch (ins.op) {
            case Numeric32Op.LEGACY_MOV:
                source.appendf("mov %%r%d, %d\n", ins.dst, ins.value);
            case Numeric32Op.SETUP_STORE:
                source.appendf("store.%s [raw_m + 0], %%r%d\n",
                    numeric32_type_name(ins.type), ins.left);
            case Numeric32Op.PRINT:
                source.appendf("print %%r%d\n", ins.left);
            case Numeric32Op.DECAY:
                source.append("decay main\n");
            case Numeric32Op.RET:
                source.append("ret\n");
            default:
                numeric32_emit_typed(&source, ins);
        }
    }
    return source.str_view();
}

fn int numeric32_valid_forms(Numeric32Op op) {
    if (op == Numeric32Op.MOV_IMM || op == Numeric32Op.MOV_REG ||
            op == Numeric32Op.INC || op == Numeric32Op.DEC ||
            op == Numeric32Op.CINC || op == Numeric32Op.CDEC) return 1;
    return 2;
}

fn Numeric32Instruction numeric32_valid_operation(int slot) {
    assert(slot >= 0 && slot < 78);
    Numeric32Instruction selected = { .dst = 2, .left = 0, .right = 1 };
    int cell = 0;
    bool found = false;
    for (int raw_op = 0; raw_op < NUMERIC32_OP_COUNT; raw_op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric32Op op = (Numeric32Op)raw_op;
            Numeric32Type type = (Numeric32Type)raw_type;
            if (!numeric32_legal(op, type)) continue;
            int forms = numeric32_valid_forms(op);
            for (int form = 0; form < forms; form++) {
                if (cell == slot) {
                    selected.op = op;
                    selected.type = type;
                    selected.immediate_rhs = forms == 2 ? form == 0
                        : op == Numeric32Op.MOV_IMM;
                    selected.dynamic_offset = (op == Numeric32Op.LOAD ||
                        op == Numeric32Op.STORE) && form == 1;
                    if (op == Numeric32Op.MOV_REG) selected.dst = 0;
                    found = true;
                }
                cell++;
            }
        }
    }
    assert(found && cell == 78);
    return selected;
}

fn void numeric32_valid_values(Numeric32Instruction* ins, int slot,
        long* left, long* right) {
    *left = (long)((ulong)(slot * 37) & 0xffffffff) |
        (long)(slot % 3 + 1) * 4294967296;
    *right = (long)((ulong)(slot * 11) & 0xffffffff) |
        (long)(slot % 2 + 1) * 8589934592;
    if (ins.op == Numeric32Op.CADD || ins.op == Numeric32Op.CMUL) {
        *left = 0x100000002;
        *right = 0x200000003;
    }
    if (ins.op == Numeric32Op.CSUB) {
        *left = ins.type == Numeric32Type.U32 ? 0x100000003 : 0x100000002;
        *right = ins.type == Numeric32Type.U32 ? 0x200000002 : 0x200000003;
    }
    if (ins.op == Numeric32Op.CINC) *left = 0x100000000;
    if (ins.op == Numeric32Op.CDEC) {
        *left = ins.type == Numeric32Type.U32 ? 0x100000001 : 0x100000000;
    }
    if (ins.op == Numeric32Op.DIV || ins.op == Numeric32Op.MOD) {
        *left = 0x100000006;
        *right = 0x200000002;
    }
    bool shift = ins.op == Numeric32Op.SHL || ins.op == Numeric32Op.SHR ||
        ins.op == Numeric32Op.USHR;
    if (shift) {
        *left = 0x180000000;
        *right = 1;
    }
    if (ins.op == Numeric32Op.LOAD || ins.op == Numeric32Op.STORE) {
        *right = ins.dynamic_offset ? 1 : 0;
    }
    ins.value = ins.immediate_rhs ? *right & 0xffffffff : *right;
    if (ins.op == Numeric32Op.MOV_IMM) ins.value = *left & 0xffffffff;
}

fn void numeric32_valid_slot(Numeric32Program* program, int slot) {
    Numeric32Instruction target = numeric32_valid_operation(slot);
    long left;
    long right;
    numeric32_valid_values(&target, slot, &left, &right);
    numeric32_push_legacy(program, 0, left);
    numeric32_push_legacy(program, 1, right);
    if (target.op == Numeric32Op.LOAD) {
        numeric32_push(program, {
            .op = Numeric32Op.SETUP_STORE, .type = target.type, .left = 0,
        });
    }
    if (target.op == Numeric32Op.INC || target.op == Numeric32Op.DEC ||
            target.op == Numeric32Op.CINC || target.op == Numeric32Op.CDEC) {
        target.dst = 0;
    }
    numeric32_push(program, target);
    if (target.op == Numeric32Op.STORE) {
        numeric32_push(program, {
            .op = Numeric32Op.LOAD, .type = target.type, .dst = 2,
            .left = 0, .right = 1, .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric32_push(program, { .op = Numeric32Op.PRINT, .left = target.dst });
}

fn Numeric32Program numeric32_valid_program(int index) {
    assert(index >= 0 && index < 64);
    Numeric32Program program = {};
    int slot = index * 2;
    numeric32_valid_slot(&program, slot % 78);
    numeric32_valid_slot(&program, (slot + 1) % 78);
    numeric32_push(&program, { .op = Numeric32Op.RET });
    return program;
}

fn Numeric32Program numeric32_fault_checked(int index) {
    Numeric32Op[] ops = {
        Numeric32Op.CADD, Numeric32Op.CADD, Numeric32Op.CSUB, Numeric32Op.CSUB,
        Numeric32Op.CMUL, Numeric32Op.CMUL, Numeric32Op.CADD, Numeric32Op.CSUB,
        Numeric32Op.CMUL, Numeric32Op.CINC, Numeric32Op.CDEC,
        Numeric32Op.CINC, Numeric32Op.CDEC,
    };
    Numeric32Type[] types = {
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.I32,
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.U32, Numeric32Type.U32,
        Numeric32Type.U32, Numeric32Type.I32, Numeric32Type.I32,
        Numeric32Type.U32, Numeric32Type.U32,
    };
    long[] left = {
        2147483647, -2147483648, 2147483647, -2147483648, 1073741824,
        -2147483648, 4294967295, 0, 4294967295, 2147483647, -2147483648,
        4294967295, 0,
    };
    long[] right = { 1, -1, -1, 1, 2, 2, 1, 1, 2, 0, 0, 0, 0 };
    assert(index >= 0 && index < 13);
    return numeric32_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric32Program numeric32_fault_division(int index) {
    Numeric32Op[] ops = {
        Numeric32Op.DIV, Numeric32Op.DIV, Numeric32Op.MOD,
        Numeric32Op.MOD, Numeric32Op.DIV, Numeric32Op.MOD,
    };
    Numeric32Type[] types = {
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.I32,
        Numeric32Type.I32, Numeric32Type.U32, Numeric32Type.U32,
    };
    long[] left = { 1, -2147483648, 1, -2147483648, 1, 1 };
    long[] right = { 0, -1, 0, -1, 0, 0 };
    assert(index >= 0 && index < 6);
    return numeric32_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric32Program numeric32_fault_shift(int index) {
    Numeric32Op[] ops = {
        Numeric32Op.SHL, Numeric32Op.SHL, Numeric32Op.SHL, Numeric32Op.SHL,
        Numeric32Op.SHR, Numeric32Op.SHR, Numeric32Op.USHR, Numeric32Op.USHR,
        Numeric32Op.USHR, Numeric32Op.USHR,
    };
    Numeric32Type[] types = {
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.U32, Numeric32Type.U32,
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.I32,
        Numeric32Type.U32, Numeric32Type.U32,
    };
    assert(index >= 0 && index < 10);
    long right = index % 2 == 0 ? -1 : 32;
    return numeric32_make_program(ops[index], types[index], 1, right, true, 0);
}

fn Numeric32Program numeric32_fault_memory(int index) {
    Numeric32Op op = index < 4 ? Numeric32Op.LOAD : Numeric32Op.STORE;
    Numeric32Type[] types = {
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.U32, Numeric32Type.U32,
        Numeric32Type.I32, Numeric32Type.I32, Numeric32Type.U32, Numeric32Type.U32,
    };
    assert(index >= 0 && index < 8);
    int mode = index % 2 == 0 ? 1 : 2;
    return numeric32_make_program(op, types[index], 2147483648, 7, false, mode);
}

fn Numeric32Program numeric32_fault_program(int index) {
    if (index < 13) return numeric32_fault_checked(index);
    if (index < 19) return numeric32_fault_division(index - 13);
    if (index < 29) return numeric32_fault_shift(index - 19);
    return numeric32_fault_memory(index - 29);
}

struct Numeric32Rng {
    ulong state;
}

fn ulong Numeric32Rng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn void numeric32_randomize_fault(Numeric32Program* program, ulong seed) {
    Numeric32Rng rng = { seed ^ 0x9e3779b97f4a7c15 };
    ulong upper_left = rng.next() & 0x7fffffff00000000;
    ulong left = (ulong)program.ops[0].value & 0xffffffff;
    program.ops[0].value = (long)(left | upper_left);
    for (int index = 0; index < program.len; index++) {
        Numeric32Instruction* target = &program.ops[index];
        if (target.op >= Numeric32Op.LEGACY_MOV) continue;
        bool shift = target.op == Numeric32Op.SHL || target.op == Numeric32Op.SHR ||
            target.op == Numeric32Op.USHR;
        if (shift && seed % 3 != 0) {
            program.ops[1].value = 33;
            target.value = 33;
            target.immediate_rhs = seed % 2 == 0;
        } else {
            if (!shift && !target.dynamic_offset) {
                ulong upper = rng.next() & 0x7fffffff00000000;
                ulong right = (ulong)program.ops[1].value & 0xffffffff;
                program.ops[1].value = (long)(right | upper);
            }
            if (rng.next() % 2 == 0) target.immediate_rhs = !target.immediate_rhs;
        }
        break;
    }
}

ulong numeric32_attempt;
int numeric32_mutation;
char[1048576] numeric32_generated_buf;

fn String numeric32_replace(String text, String needle, String replacement,
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

fn void numeric32_mutate_generated(String path) {
    if (numeric32_mutation == 0) return;
    char[] data = read_file(path, numeric32_generated_buf[..]) ?? unreachable();
    String from = numeric32_mutation == 1
        ? "rez_i32_from_bits" : "if (rez_i32_cadd(";
    String to = numeric32_mutation == 1
        ? "rez_u32_from_bits" : "if (false && rez_i32_cadd(";
    bool changed;
    String mutated = numeric32_replace((String)data, from, to, &changed);
    if (!changed) return;
    write_file(path, mutated) ?? unreachable();
}

enum Numeric32FailureKind : char {
    NONE,
    EMIT,
    COMPILE,
    RUNTIME,
}

struct Numeric32Failure {
    Numeric32FailureKind kind;
    int expected_status;
    int actual_status;
    DString expected_output;
    DString expected_errors;
    DString actual_output;
    DString actual_errors;
}

fn Numeric32Failure numeric32_failure(Numeric32Program program) {
    Numeric32Expected expected = numeric32_reference(&program);
    Numeric32Failure failure = {
        .expected_status = expected.status,
        .expected_output = dstring::temp(normalize_lines(expected.output.str_view())),
        .expected_errors = dstring::temp(normalize_lines(expected.errors.str_view())),
    };
    String source = numeric32_source(&program);
    assert(numeric32_attempt < 1000000);
    String name = string::tformat("numeric32-%d.rza", numeric32_attempt);
    numeric32_attempt++;
    String path = temp_path(name);
    write_file(path, source) ?? unreachable();
    String generated = string::tformat("%s.c", path);
    ProcessResult emitted = run_simple({
        compiler_path(), path, "--emit-c", "-o", generated,
    }) ?? unreachable();
    if (emitted.status != 0 || emitted.stdout_text.len != 0 ||
            emitted.stderr_text.len != 0) {
        failure.kind = Numeric32FailureKind.EMIT;
        failure.actual_status = emitted.status;
        failure.actual_output = dstring::temp(normalize_lines(emitted.stdout_text));
        failure.actual_errors = dstring::temp(normalize_lines(emitted.stderr_text));
        return failure;
    }
    numeric32_mutate_generated(generated);
    String executable = string::tformat("%s.exe", path);
    ProcessResult compiled = compile_c(generated, executable) ?? unreachable();
    if (compiled.status != 0 || compiled.stderr_text.len != 0) {
        failure.kind = Numeric32FailureKind.COMPILE;
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
        failure.kind = Numeric32FailureKind.RUNTIME;
        io::eprintfn("numeric32 expected status=%d stdout=%s stderr=%s",
            expected.status, expected.output.str_view(), expected.errors.str_view());
        print_result(runtime);
    }
    return failure;
}

fn bool numeric32_failure_same(Numeric32Program candidate, Numeric32Failure original) {
    Numeric32Failure current = numeric32_failure(candidate);
    return current.kind == original.kind &&
        current.expected_status == original.expected_status &&
        current.actual_status == original.actual_status &&
        current.expected_output.str_view() == original.expected_output.str_view() &&
        current.expected_errors.str_view() == original.expected_errors.str_view() &&
        current.actual_output.str_view() == original.actual_output.str_view() &&
        current.actual_errors.str_view() == original.actual_errors.str_view();
}

fn bool numeric32_program_fails(Numeric32Program program) {
    return numeric32_failure(program).kind != Numeric32FailureKind.NONE;
}

fn Numeric32Program numeric32_remove(Numeric32Program program, int index) {
    assert(index >= 0 && index < program.len);
    for (int i = index + 1; i < program.len; i++) program.ops[i - 1] = program.ops[i];
    program.len--;
    return program;
}

fn Numeric32Program numeric32_shrink(Numeric32Program world) {
    Numeric32Failure original = numeric32_failure(world);
    assert(original.kind != Numeric32FailureKind.NONE);
    Numeric32Program best = world;
    for (int round = 0; round < 16; round++) {
        bool changed = false;
        for (int index = 0; index < best.len; index++) {
            Numeric32Op op = best.ops[index].op;
            if (op == Numeric32Op.PRINT || op == Numeric32Op.RET) continue;
            Numeric32Program candidate = numeric32_remove(best, index);
            if (numeric32_failure_same(candidate, original)) {
                best = candidate;
                changed = true;
            }
        }
        if (!changed) break;
    }
    assert(numeric32_failure_same(best, original));
    return best;
}

fn int numeric32_mutation_selftest() {
    Numeric32Program load = numeric32_make_program(Numeric32Op.LOAD,
        Numeric32Type.I32, 2147483648, 0, false, 0);
    if (!expect(!numeric32_program_fails(load), "numeric32 load fixture")) return 1;
    numeric32_mutation = 1;
    if (!expect(numeric32_program_fails(load),
            "oracle detects wrong i32 sign extension")) return 1;
    numeric32_mutation = 0;
    Numeric32Program checked = numeric32_make_program(Numeric32Op.CADD,
        Numeric32Type.I32, 2147483647, 1, true, 0);
    if (!expect(!numeric32_program_fails(checked), "numeric32 checked fixture")) return 1;
    numeric32_mutation = 2;
    if (!expect(numeric32_program_fails(checked),
            "oracle detects removed checked-overflow guard")) return 1;
    numeric32_mutation = 0;
    return 0;
}

fn int numeric32_shrink_selftest() {
    Numeric32Program program = {};
    numeric32_push_legacy(&program, 0, 2147483648);
    numeric32_push(&program, {
        .op = Numeric32Op.SETUP_STORE, .type = Numeric32Type.I32, .left = 0,
    });
    numeric32_push_legacy(&program, 1, 1);
    numeric32_push(&program, {
        .op = Numeric32Op.ADD, .type = Numeric32Type.I32, .dst = 1,
        .left = 1, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric32_push(&program, {
        .op = Numeric32Op.LOAD, .type = Numeric32Type.I32, .dst = 2, .left = 0,
    });
    numeric32_push(&program, { .op = Numeric32Op.PRINT, .left = 2 });
    numeric32_push(&program, { .op = Numeric32Op.RET });
    numeric32_mutation = 1;
    if (!expect(numeric32_program_fails(program), "numeric32 shrink fixture")) return 1;
    Numeric32Program reduced = numeric32_shrink(program);
    bool has_add = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric32Op.ADD) has_add = true;
    }
    if (!expect(reduced.len == 5 && !has_add && numeric32_program_fails(reduced),
            "numeric32 shrink removes irrelevant instructions without stale artifacts")) {
        return 1;
    }
    numeric32_mutation = 0;
    return 0;
}

fn int numeric32_shrink_signature_selftest() {
    Numeric32Program original = {};
    numeric32_push_legacy(&original, 0, 2147483647);
    numeric32_push_legacy(&original, 1, 1);
    numeric32_push(&original, {
        .op = Numeric32Op.CADD, .type = Numeric32Type.I32, .dst = 2,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric32_push(&original, {
        .op = Numeric32Op.ADD, .type = Numeric32Type.I32, .dst = 3,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric32_push(&original, { .op = Numeric32Op.PRINT, .left = 2 });
    numeric32_push(&original, { .op = Numeric32Op.PRINT, .left = 3 });
    numeric32_push(&original, { .op = Numeric32Op.RET });
    Numeric32Program replacement = numeric32_remove(original, 3);
    numeric32_mutation = 2;
    if (!expect(numeric32_program_fails(replacement),
            "replacement failure remains a failure")) return 1;
    Numeric32Failure original_failure = numeric32_failure(original);
    if (!expect(!numeric32_failure_same(replacement, original_failure),
            "shrink must not accept a different failure signature")) return 1;
    Numeric32Program reduced = numeric32_shrink(original);
    bool has_add = false;
    bool has_cadd = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric32Op.ADD) has_add = true;
        if (reduced.ops[i].op == Numeric32Op.CADD) has_cadd = true;
    }
    numeric32_mutation = 0;
    if (!expect(has_add && has_cadd, "shrink preserves the original operation mix")) {
        return 1;
    }
    return 0;
}

fn int numeric32_run_program(Numeric32Program program) {
    if (!numeric32_program_fails(program)) return 0;
    Numeric32Program reduced = numeric32_shrink(program);
    io::eprintn(numeric32_source(&reduced));
    return 1;
}

fn int numeric32_oracle_main() {
    defer (void)cleanup_temp_dir();
    reset_temp_dir() ?? unreachable();
    if (numeric32_reference_selftest() != 0) return 1;
    if (numeric32_mutation_selftest() != 0) return 1;
    if (numeric32_shrink_selftest() != 0) return 1;
    if (numeric32_shrink_signature_selftest() != 0) return 1;
    numeric32_coverage_reset();
    for (int index = 0; index < 64; index++) {
        Numeric32Program program = numeric32_valid_program(index);
        ulong faults_before = numeric32_coverage.faults;
        if (numeric32_run_program(program) != 0) return 1;
        if (numeric32_coverage.faults != faults_before) {
            io::eprintfn("numeric32 valid index=%d unexpectedly faulted", index);
            io::eprintn(numeric32_source(&program));
            return 1;
        }
    }
    for (int index = 0; index < 64; index++) {
        Numeric32Program program = numeric32_fault_program(index % 37);
        if (index >= 37) numeric32_randomize_fault(&program, (ulong)index);
        numeric32_direct_attribution = index < 37;
        ulong valid_before = numeric32_coverage.valid;
        if (numeric32_run_program(program) != 0) return 1;
        if (numeric32_coverage.valid != valid_before) {
            io::eprintfn("numeric32 fault index=%d unexpectedly succeeded", index);
            io::eprintn(numeric32_source(&program));
            return 1;
        }
    }
    numeric32_direct_attribution = false;
    numeric32_coverage_print();
    if (!numeric32_coverage_ok()) return 1;
    io::printn("NUMERIC32_ORACLE OK (128 programs)");
    return 0;
}
