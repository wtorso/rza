module rza_tests;

import std::core::dstring;
import std::io;

const int NUMERIC16_PROGRAM_OPS_MAX = 16;

struct Numeric16Instruction {
    Numeric16Op op;
    Numeric16Type type;
    int dst;
    int left;
    int right;
    long value;
    bool immediate_rhs;
    bool dynamic_offset;
}

struct Numeric16Program {
    Numeric16Instruction[NUMERIC16_PROGRAM_OPS_MAX] ops;
    int len;
}

struct Numeric16Expected {
    DString output;
    DString errors;
    int status;
}

union Numeric16NativeWord {
    ushort value;
    char[2] bytes;
}

fn void numeric16_push(Numeric16Program* program, Numeric16Instruction ins) {
    assert(program.len >= 0 && program.len < NUMERIC16_PROGRAM_OPS_MAX);
    program.ops[program.len] = ins;
    program.len++;
}

fn void numeric16_push_legacy(Numeric16Program* program, int dst, long value) {
    numeric16_push(program, {
        .op = Numeric16Op.LEGACY_MOV, .dst = dst, .value = value,
    });
}

fn Numeric16Program numeric16_make_program(Numeric16Op op, Numeric16Type type,
        long left, long right, bool immediate, int fault_mode) {
    Numeric16Program program = {};
    numeric16_push_legacy(&program, 0, left);
    numeric16_push_legacy(&program, 1, right);
    if (op == Numeric16Op.LOAD) {
        numeric16_push(&program, {
            .op = Numeric16Op.SETUP_STORE, .type = type, .left = 0,
        });
    }
    if (fault_mode == 2) numeric16_push(&program, { .op = Numeric16Op.DECAY });
    Numeric16Instruction target = {
        .op = op, .type = type, .dst = 2, .left = 0, .right = 1,
        .value = right, .immediate_rhs = immediate,
        .dynamic_offset = fault_mode == 1,
    };
    if (op == Numeric16Op.MOV_IMM) target.value = left;
    if (op == Numeric16Op.INC || op == Numeric16Op.DEC ||
            op == Numeric16Op.CINC || op == Numeric16Op.CDEC) {
        target.dst = 0;
    }
    numeric16_push(&program, target);
    if (op == Numeric16Op.STORE) {
        numeric16_push(&program, {
            .op = Numeric16Op.LOAD, .type = type, .dst = 2, .right = 1,
            .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric16_push(&program, {
        .op = Numeric16Op.PRINT, .left = target.dst,
    });
    numeric16_push(&program, { .op = Numeric16Op.RET });
    return program;
}

fn int numeric16_fault_line(int index) {
    assert(index >= 0 && index < NUMERIC16_PROGRAM_OPS_MAX);
    return index + 4;
}

fn bool numeric16_memory_fault(Numeric16Instruction ins, long offset,
        bool alive, DString* errors, int line) {
    if (!alive) {
        errors.appendf("FAULT line %d: dead mediator raw_m\n", line);
        numeric16_cover_fault(ins.op, ins.type, Numeric16Fault.DEAD);
        return true;
    }
    if (offset < 0 || offset >= 3) {
        errors.appendf("FAULT line %d: out of bounds raw_m\n", line);
        numeric16_cover_fault(ins.op, ins.type, Numeric16Fault.BOUNDS);
        return true;
    }
    return false;
}

fn bool numeric16_immediate_form(Numeric16Instruction ins) {
    if (ins.op == Numeric16Op.MOV_IMM) return true;
    if (ins.op == Numeric16Op.MOV_REG || ins.op == Numeric16Op.INC ||
            ins.op == Numeric16Op.DEC || ins.op == Numeric16Op.CINC ||
            ins.op == Numeric16Op.CDEC) return false;
    if (ins.op == Numeric16Op.LOAD || ins.op == Numeric16Op.STORE) {
        return !ins.dynamic_offset;
    }
    return ins.immediate_rhs;
}

fn bool numeric16_dirty_input(Numeric16Instruction ins, long left, long right) {
    if (ins.op == Numeric16Op.MOV_IMM) return false;
    if (((ulong)left & ~0xffffUL) != 0) return true;
    bool shift = ins.op == Numeric16Op.SHL || ins.op == Numeric16Op.SHR ||
        ins.op == Numeric16Op.USHR;
    bool unary = ins.op == Numeric16Op.INC || ins.op == Numeric16Op.DEC ||
        ins.op == Numeric16Op.CINC || ins.op == Numeric16Op.CDEC;
    if (ins.op == Numeric16Op.MOV_REG || ins.op == Numeric16Op.LOAD ||
            ins.op == Numeric16Op.STORE || shift || unary || ins.immediate_rhs) {
        return false;
    }
    return ((ulong)right & ~0xffffUL) != 0;
}

fn void numeric16_cover_execution(Numeric16Instruction ins, long left, long right) {
    numeric16_cover_success(ins.op, ins.type, numeric16_immediate_form(ins),
        numeric16_dirty_input(ins, left, right));
}

fn void numeric16_setup_cell(Numeric16Type type, long value, char[] cell) {
    assert(cell.len == 4);
    Numeric16NativeWord setup = { .value = (ushort)((ulong)value & 0xffff) };
    cell[0] = setup.bytes[0];
    cell[1] = setup.bytes[1];
}

fn void numeric16_access_cell(Numeric16Instruction ins, long offset,
        long left, long* result, char[] cell) {
    assert(cell.len == 4 && offset >= 0 && offset < 3);
    sz index = (sz)offset;
    Numeric16NativeWord converted;
    if (ins.op == Numeric16Op.LOAD) {
        converted.bytes[0] = cell[index];
        converted.bytes[1] = cell[index + 1];
        *result = numeric16_normalize(ins.type, (ulong)converted.value);
        return;
    }
    converted.value = (ushort)((ulong)left & 0xffff);
    cell[index] = converted.bytes[0];
    cell[index + 1] = converted.bytes[1];
}

fn Numeric16Expected numeric16_reference(Numeric16Program* program) {
    long[16] regs = {};
    char[4] cell = {};
    bool alive = true;
    DString output = dstring::temp();
    DString errors = dstring::temp();
    for (int index = 0; index < program.len; index++) {
        Numeric16Instruction ins = program.ops[index];
        int line = numeric16_fault_line(index);
        if (ins.op == Numeric16Op.RET) {
            numeric16_coverage.valid++;
            return { output, errors, 0 };
        }
        if (ins.op == Numeric16Op.DECAY) {
            alive = false;
            continue;
        }
        if (ins.op == Numeric16Op.PRINT) {
            output.appendf("%d\n", regs[ins.left]);
            continue;
        }
        if (ins.op == Numeric16Op.LEGACY_MOV) {
            regs[ins.dst] = ins.value;
            continue;
        }
        if (ins.op == Numeric16Op.SETUP_STORE) {
            numeric16_setup_cell(ins.type, regs[ins.left], cell[..]);
            continue;
        }
        long left = regs[ins.left];
        long right = ins.immediate_rhs ? ins.value : regs[ins.right];
        if (ins.op == Numeric16Op.LOAD || ins.op == Numeric16Op.STORE) {
            long offset = ins.dynamic_offset ? regs[ins.right] : 0;
            if (numeric16_memory_fault(ins, offset, alive, &errors, line)) {
                return { output, errors, 1 };
            }
            numeric16_access_cell(ins, offset, left, &regs[ins.dst], cell[..]);
            numeric16_cover_execution(ins, left, right);
            continue;
        }
        if (ins.op == Numeric16Op.MOV_IMM) {
            regs[ins.dst] = numeric16_normalize(ins.type, (ulong)ins.value);
        } else if (ins.op == Numeric16Op.MOV_REG) {
            regs[ins.dst] = numeric16_normalize(ins.type, (ulong)left);
        } else {
            Numeric16Fault failure;
            long value = numeric16_evaluate(ins.op, ins.type, left, right, &failure);
            if (failure != Numeric16Fault.NONE) {
                String reason = failure == Numeric16Fault.ARITHMETIC ? "arithmetic overflow"
                    : failure == Numeric16Fault.DIVISION ? "division" : "shift";
                errors.appendf("FAULT line %d: %s\n", line, reason);
                numeric16_cover_fault(ins.op, ins.type, failure);
                return { output, errors, 1 };
            }
            regs[ins.dst] = value;
        }
        numeric16_cover_execution(ins, left, right);
    }
    unreachable("numeric16 reference requires ret");
}

fn String numeric16_type_name(Numeric16Type type) {
    return type == Numeric16Type.I16 ? "i16" : "u16";
}

fn String numeric16_op_name(Numeric16Op op) {
    switch (op) {
        case Numeric16Op.MOV_IMM: case Numeric16Op.MOV_REG: return "mov";
        case Numeric16Op.LOAD: return "load";
        case Numeric16Op.STORE: return "store";
        case Numeric16Op.ADD: return "add";
        case Numeric16Op.SUB: return "sub";
        case Numeric16Op.MUL: return "mul";
        case Numeric16Op.INC: return "inc";
        case Numeric16Op.DEC: return "dec";
        case Numeric16Op.CADD: return "cadd";
        case Numeric16Op.CSUB: return "csub";
        case Numeric16Op.CMUL: return "cmul";
        case Numeric16Op.CINC: return "cinc";
        case Numeric16Op.CDEC: return "cdec";
        case Numeric16Op.AND: return "and";
        case Numeric16Op.OR: return "or";
        case Numeric16Op.XOR: return "xor";
        case Numeric16Op.SLT: return "slt";
        case Numeric16Op.ULT: return "ult";
        case Numeric16Op.DIV: return "div";
        case Numeric16Op.MOD: return "mod";
        case Numeric16Op.SHL: return "shl";
        case Numeric16Op.SHR: return "shr";
        case Numeric16Op.USHR: return "ushr";
        default: unreachable("not a typed numeric16 opcode");
    }
}

fn void numeric16_emit_typed(DString* source, Numeric16Instruction ins) {
    String op = numeric16_op_name(ins.op);
    String type = numeric16_type_name(ins.type);
    if (ins.op == Numeric16Op.MOV_IMM) {
        source.appendf("mov.%s %%r%d, 0x%04x\n", type, ins.dst,
            (uint)ins.value & 0xffff);
        return;
    }
    if (ins.op == Numeric16Op.MOV_REG) {
        source.appendf("mov.%s %%r%d, %%r%d\n", type, ins.dst, ins.left);
        return;
    }
    if (ins.op == Numeric16Op.LOAD || ins.op == Numeric16Op.STORE) {
        DString offset = dstring::temp();
        if (ins.dynamic_offset) {
            offset.appendf("%%r%d", ins.right);
        } else {
            offset.append("0");
        }
        if (ins.op == Numeric16Op.LOAD) {
            source.appendf("load.%s %%r%d, [raw_m + %s]\n", type, ins.dst,
                offset.str_view());
        } else {
            source.appendf("store.%s [raw_m + %s], %%r%d\n", type,
                offset.str_view(), ins.left);
        }
        return;
    }
    if (ins.op == Numeric16Op.INC || ins.op == Numeric16Op.DEC ||
            ins.op == Numeric16Op.CINC || ins.op == Numeric16Op.CDEC) {
        source.appendf("%s.%s %%r%d\n", op, type, ins.dst);
        return;
    }
    source.appendf("%s.%s %%r%d, %%r%d, ", op, type, ins.dst, ins.left);
    if (!ins.immediate_rhs) {
        source.appendf("%%r%d\n", ins.right);
        return;
    }
    bool shift = ins.op == Numeric16Op.SHL || ins.op == Numeric16Op.SHR ||
        ins.op == Numeric16Op.USHR;
    if (shift) {
        source.appendf("%d\n", ins.value);
    } else {
        source.appendf("0x%04x\n", (uint)ins.value & 0xffff);
    }
}

fn String numeric16_source(Numeric16Program* program) {
    DString source = dstring::temp("cav main, field\nres raw, main, 4\n"
        "med raw_m, raw, main\n");
    for (int index = 0; index < program.len; index++) {
        Numeric16Instruction ins = program.ops[index];
        switch (ins.op) {
            case Numeric16Op.LEGACY_MOV:
                source.appendf("mov %%r%d, %d\n", ins.dst, ins.value);
            case Numeric16Op.SETUP_STORE:
                source.appendf("store.%s [raw_m + 0], %%r%d\n",
                    numeric16_type_name(ins.type), ins.left);
            case Numeric16Op.PRINT:
                source.appendf("print %%r%d\n", ins.left);
            case Numeric16Op.DECAY:
                source.append("decay main\n");
            case Numeric16Op.RET:
                source.append("ret\n");
            default:
                numeric16_emit_typed(&source, ins);
        }
    }
    return source.str_view();
}

fn int numeric16_valid_forms(Numeric16Op op) {
    if (op == Numeric16Op.MOV_IMM || op == Numeric16Op.MOV_REG ||
            op == Numeric16Op.INC || op == Numeric16Op.DEC ||
            op == Numeric16Op.CINC || op == Numeric16Op.CDEC) return 1;
    return 2;
}

fn Numeric16Instruction numeric16_valid_operation(int slot) {
    assert(slot >= 0 && slot < 78);
    Numeric16Instruction selected = { .dst = 2, .left = 0, .right = 1 };
    int cell = 0;
    bool found = false;
    for (int raw_op = 0; raw_op < NUMERIC16_OP_COUNT; raw_op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric16Op op = (Numeric16Op)raw_op;
            Numeric16Type type = (Numeric16Type)raw_type;
            if (!numeric16_legal(op, type)) continue;
            int forms = numeric16_valid_forms(op);
            for (int form = 0; form < forms; form++) {
                if (cell == slot) {
                    selected.op = op;
                    selected.type = type;
                    selected.immediate_rhs = forms == 2 ? form == 0
                        : op == Numeric16Op.MOV_IMM;
                    selected.dynamic_offset = (op == Numeric16Op.LOAD ||
                        op == Numeric16Op.STORE) && form == 1;
                    if (op == Numeric16Op.MOV_REG) selected.dst = 0;
                    found = true;
                }
                cell++;
            }
        }
    }
    assert(found && cell == 78);
    return selected;
}

fn void numeric16_valid_values(Numeric16Instruction* ins, int slot,
        long* left, long* right) {
    *left = (long)((slot * 37) & 0xffff) | (long)((slot % 3 + 1) * 65536);
    *right = (long)((slot * 11) & 0xffff) | (long)((slot % 2 + 1) * 131072);
    if (ins.op == Numeric16Op.CADD || ins.op == Numeric16Op.CMUL) {
        *left = 0x10002;
        *right = 0x20003;
    }
    if (ins.op == Numeric16Op.CSUB) {
        *left = ins.type == Numeric16Type.U16 ? 0x10003 : 0x10002;
        *right = ins.type == Numeric16Type.U16 ? 0x20002 : 0x20003;
    }
    if (ins.op == Numeric16Op.CINC) *left = 0x10000;
    if (ins.op == Numeric16Op.CDEC) {
        *left = ins.type == Numeric16Type.U16 ? 0x10001 : 0x10000;
    }
    if (ins.op == Numeric16Op.DIV || ins.op == Numeric16Op.MOD) {
        *left = 0x10006;
        *right = 0x20002;
    }
    bool shift = ins.op == Numeric16Op.SHL || ins.op == Numeric16Op.SHR ||
        ins.op == Numeric16Op.USHR;
    if (shift) {
        *left = 0x18000;
        *right = 1;
    }
    if (ins.op == Numeric16Op.LOAD || ins.op == Numeric16Op.STORE) {
        *right = ins.dynamic_offset ? 1 : 0;
    }
    ins.value = ins.immediate_rhs ? *right & 0xffff : *right;
    if (ins.op == Numeric16Op.MOV_IMM) ins.value = *left & 0xffff;
}

fn void numeric16_valid_slot(Numeric16Program* program, int slot) {
    Numeric16Instruction target = numeric16_valid_operation(slot);
    long left;
    long right;
    numeric16_valid_values(&target, slot, &left, &right);
    numeric16_push_legacy(program, 0, left);
    numeric16_push_legacy(program, 1, right);
    if (target.op == Numeric16Op.LOAD) {
        numeric16_push(program, {
            .op = Numeric16Op.SETUP_STORE, .type = target.type, .left = 0,
        });
    }
    if (target.op == Numeric16Op.INC || target.op == Numeric16Op.DEC ||
            target.op == Numeric16Op.CINC || target.op == Numeric16Op.CDEC) {
        target.dst = 0;
    }
    numeric16_push(program, target);
    if (target.op == Numeric16Op.STORE) {
        numeric16_push(program, {
            .op = Numeric16Op.LOAD, .type = target.type, .dst = 2,
            .left = 0, .right = 1, .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric16_push(program, { .op = Numeric16Op.PRINT, .left = target.dst });
}

fn Numeric16Program numeric16_valid_program(int index) {
    assert(index >= 0 && index < 64);
    Numeric16Program program = {};
    int slot = index * 2;
    numeric16_valid_slot(&program, slot % 78);
    numeric16_valid_slot(&program, (slot + 1) % 78);
    numeric16_push(&program, { .op = Numeric16Op.RET });
    return program;
}

fn Numeric16Program numeric16_fault_checked(int index) {
    Numeric16Op[] ops = {
        Numeric16Op.CADD, Numeric16Op.CADD, Numeric16Op.CSUB, Numeric16Op.CSUB,
        Numeric16Op.CMUL, Numeric16Op.CMUL, Numeric16Op.CADD, Numeric16Op.CSUB,
        Numeric16Op.CMUL, Numeric16Op.CINC, Numeric16Op.CDEC,
        Numeric16Op.CINC, Numeric16Op.CDEC,
    };
    Numeric16Type[] types = {
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.I16,
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.U16, Numeric16Type.U16,
        Numeric16Type.U16, Numeric16Type.I16, Numeric16Type.I16,
        Numeric16Type.U16, Numeric16Type.U16,
    };
    long[] left = {
        32767, -32768, 32767, -32768, 16384, -32768, 65535,
        0, 65535, 32767, -32768, 65535, 0,
    };
    long[] right = { 1, -1, -1, 1, 2, 2, 1, 1, 2, 0, 0, 0, 0 };
    assert(index >= 0 && index < 13);
    return numeric16_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric16Program numeric16_fault_division(int index) {
    Numeric16Op[] ops = {
        Numeric16Op.DIV, Numeric16Op.DIV, Numeric16Op.MOD,
        Numeric16Op.MOD, Numeric16Op.DIV, Numeric16Op.MOD,
    };
    Numeric16Type[] types = {
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.I16,
        Numeric16Type.I16, Numeric16Type.U16, Numeric16Type.U16,
    };
    long[] left = { 1, -32768, 1, -32768, 1, 1 };
    long[] right = { 0, -1, 0, -1, 0, 0 };
    assert(index >= 0 && index < 6);
    return numeric16_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric16Program numeric16_fault_shift(int index) {
    Numeric16Op[] ops = {
        Numeric16Op.SHL, Numeric16Op.SHL, Numeric16Op.SHL, Numeric16Op.SHL,
        Numeric16Op.SHR, Numeric16Op.SHR, Numeric16Op.USHR, Numeric16Op.USHR,
        Numeric16Op.USHR, Numeric16Op.USHR,
    };
    Numeric16Type[] types = {
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.U16, Numeric16Type.U16,
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.I16,
        Numeric16Type.U16, Numeric16Type.U16,
    };
    assert(index >= 0 && index < 10);
    long right = index % 2 == 0 ? -1 : 16;
    return numeric16_make_program(ops[index], types[index], 1, right, true, 0);
}

fn Numeric16Program numeric16_fault_memory(int index) {
    Numeric16Op op = index < 4 ? Numeric16Op.LOAD : Numeric16Op.STORE;
    Numeric16Type[] types = {
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.U16, Numeric16Type.U16,
        Numeric16Type.I16, Numeric16Type.I16, Numeric16Type.U16, Numeric16Type.U16,
    };
    assert(index >= 0 && index < 8);
    int mode = index % 2 == 0 ? 1 : 2;
    return numeric16_make_program(op, types[index], 32768, 3, false, mode);
}

fn Numeric16Program numeric16_fault_program(int index) {
    if (index < 13) return numeric16_fault_checked(index);
    if (index < 19) return numeric16_fault_division(index - 13);
    if (index < 29) return numeric16_fault_shift(index - 19);
    return numeric16_fault_memory(index - 29);
}

struct Numeric16Rng {
    ulong state;
}

fn ulong Numeric16Rng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn void numeric16_randomize_fault(Numeric16Program* program, ulong seed) {
    Numeric16Rng rng = { seed ^ 0x9e3779b97f4a7c15 };
    ulong upper_left = rng.next() & 0x7fffffffffff0000;
    ulong left = (ulong)program.ops[0].value & 0xffff;
    program.ops[0].value = (long)(left | upper_left);
    for (int index = 0; index < program.len; index++) {
        Numeric16Instruction* target = &program.ops[index];
        if (target.op >= Numeric16Op.LEGACY_MOV) continue;
        bool shift = target.op == Numeric16Op.SHL || target.op == Numeric16Op.SHR ||
            target.op == Numeric16Op.USHR;
        if (!shift && !target.dynamic_offset) {
            ulong upper = rng.next() & 0x7fffffffffff0000;
            ulong right = (ulong)program.ops[1].value & 0xffff;
            program.ops[1].value = (long)(right | upper);
        }
        if (rng.next() % 2 == 0) target.immediate_rhs = !target.immediate_rhs;
        break;
    }
}

ulong numeric16_attempt;
int numeric16_mutation;
char[1048576] numeric16_generated_buf;

fn String numeric16_replace(String text, String needle, String replacement,
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

fn void numeric16_mutate_generated(String path) {
    if (numeric16_mutation == 0) return;
    char[] data = read_file(path, numeric16_generated_buf[..]) ?? unreachable();
    String from = numeric16_mutation == 1
        ? "rez_i16_from_bits" : "if (rez_i16_cadd(";
    String to = numeric16_mutation == 1
        ? "rez_u16_from_bits" : "if (false && rez_i16_cadd(";
    bool changed;
    String mutated = numeric16_replace((String)data, from, to, &changed);
    if (!changed) return;
    write_file(path, mutated) ?? unreachable();
}

enum Numeric16FailureKind : char {
    NONE,
    EMIT,
    COMPILE,
    RUNTIME,
}

struct Numeric16Failure {
    Numeric16FailureKind kind;
    int expected_status;
    int actual_status;
    DString expected_output;
    DString expected_errors;
    DString actual_output;
    DString actual_errors;
}

fn Numeric16Failure numeric16_failure(Numeric16Program program) {
    Numeric16Expected expected = numeric16_reference(&program);
    Numeric16Failure failure = {
        .expected_status = expected.status,
        .expected_output = dstring::temp(normalize_lines(expected.output.str_view())),
        .expected_errors = dstring::temp(normalize_lines(expected.errors.str_view())),
    };
    String source = numeric16_source(&program);
    assert(numeric16_attempt < 1000000);
    String name = string::tformat("numeric16-%d.rza", numeric16_attempt);
    numeric16_attempt++;
    String path = temp_path(name);
    write_file(path, source) ?? unreachable();
    String generated = string::tformat("%s.c", path);
    ProcessResult emitted = run_simple({
        compiler_path(), path, "--emit-c", "-o", generated,
    }) ?? unreachable();
    if (emitted.status != 0 || emitted.stdout_text.len != 0 ||
            emitted.stderr_text.len != 0) {
        failure.kind = Numeric16FailureKind.EMIT;
        failure.actual_status = emitted.status;
        failure.actual_output = dstring::temp(normalize_lines(emitted.stdout_text));
        failure.actual_errors = dstring::temp(normalize_lines(emitted.stderr_text));
        return failure;
    }
    numeric16_mutate_generated(generated);
    String executable = string::tformat("%s.exe", path);
    ProcessResult compiled = compile_c(generated, executable) ?? unreachable();
    if (compiled.status != 0 || compiled.stderr_text.len != 0) {
        failure.kind = Numeric16FailureKind.COMPILE;
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
        failure.kind = Numeric16FailureKind.RUNTIME;
        io::eprintfn("numeric16 expected status=%d stdout=%s stderr=%s",
            expected.status, expected.output.str_view(), expected.errors.str_view());
        print_result(runtime);
    }
    return failure;
}

fn bool numeric16_failure_same(Numeric16Program candidate, Numeric16Failure original) {
    Numeric16Failure current = numeric16_failure(candidate);
    return current.kind == original.kind &&
        current.expected_status == original.expected_status &&
        current.actual_status == original.actual_status &&
        current.expected_output.str_view() == original.expected_output.str_view() &&
        current.expected_errors.str_view() == original.expected_errors.str_view() &&
        current.actual_output.str_view() == original.actual_output.str_view() &&
        current.actual_errors.str_view() == original.actual_errors.str_view();
}

fn bool numeric16_program_fails(Numeric16Program program) {
    return numeric16_failure(program).kind != Numeric16FailureKind.NONE;
}

fn Numeric16Program numeric16_remove(Numeric16Program program, int index) {
    assert(index >= 0 && index < program.len);
    for (int i = index + 1; i < program.len; i++) program.ops[i - 1] = program.ops[i];
    program.len--;
    return program;
}

fn Numeric16Program numeric16_shrink(Numeric16Program world) {
    Numeric16Failure original = numeric16_failure(world);
    assert(original.kind != Numeric16FailureKind.NONE);
    Numeric16Program best = world;
    for (int round = 0; round < 16; round++) {
        bool changed = false;
        for (int index = 0; index < best.len; index++) {
            Numeric16Op op = best.ops[index].op;
            if (op == Numeric16Op.PRINT || op == Numeric16Op.RET) continue;
            Numeric16Program candidate = numeric16_remove(best, index);
            if (numeric16_failure_same(candidate, original)) {
                best = candidate;
                changed = true;
            }
        }
        if (!changed) break;
    }
    assert(numeric16_failure_same(best, original));
    return best;
}

fn int numeric16_mutation_selftest() {
    Numeric16Program load = numeric16_make_program(Numeric16Op.LOAD,
        Numeric16Type.I16, 32768, 0, false, 0);
    if (!expect(!numeric16_program_fails(load), "numeric16 load fixture")) return 1;
    numeric16_mutation = 1;
    if (!expect(numeric16_program_fails(load),
            "oracle detects wrong i16 sign extension")) return 1;
    numeric16_mutation = 0;
    Numeric16Program checked = numeric16_make_program(Numeric16Op.CADD,
        Numeric16Type.I16, 32767, 1, true, 0);
    if (!expect(!numeric16_program_fails(checked), "numeric16 checked fixture")) return 1;
    numeric16_mutation = 2;
    if (!expect(numeric16_program_fails(checked),
            "oracle detects removed checked-overflow guard")) return 1;
    numeric16_mutation = 0;
    return 0;
}

fn int numeric16_shrink_selftest() {
    Numeric16Program program = {};
    numeric16_push_legacy(&program, 0, 32768);
    numeric16_push(&program, {
        .op = Numeric16Op.SETUP_STORE, .type = Numeric16Type.I16, .left = 0,
    });
    numeric16_push_legacy(&program, 1, 1);
    numeric16_push(&program, {
        .op = Numeric16Op.ADD, .type = Numeric16Type.I16, .dst = 1,
        .left = 1, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric16_push(&program, {
        .op = Numeric16Op.LOAD, .type = Numeric16Type.I16, .dst = 2, .left = 0,
    });
    numeric16_push(&program, { .op = Numeric16Op.PRINT, .left = 2 });
    numeric16_push(&program, { .op = Numeric16Op.RET });
    numeric16_mutation = 1;
    if (!expect(numeric16_program_fails(program), "numeric16 shrink fixture")) return 1;
    Numeric16Program reduced = numeric16_shrink(program);
    bool has_add = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric16Op.ADD) has_add = true;
    }
    if (!expect(reduced.len == 5 && !has_add && numeric16_program_fails(reduced),
            "numeric16 shrink removes irrelevant instructions without stale artifacts")) {
        return 1;
    }
    numeric16_mutation = 0;
    return 0;
}

fn int numeric16_shrink_signature_selftest() {
    Numeric16Program original = {};
    numeric16_push_legacy(&original, 0, 32767);
    numeric16_push_legacy(&original, 1, 1);
    numeric16_push(&original, {
        .op = Numeric16Op.CADD, .type = Numeric16Type.I16, .dst = 2,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric16_push(&original, {
        .op = Numeric16Op.ADD, .type = Numeric16Type.I16, .dst = 3,
        .left = 0, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric16_push(&original, { .op = Numeric16Op.PRINT, .left = 2 });
    numeric16_push(&original, { .op = Numeric16Op.PRINT, .left = 3 });
    numeric16_push(&original, { .op = Numeric16Op.RET });
    Numeric16Program replacement = numeric16_remove(original, 3);
    numeric16_mutation = 2;
    if (!expect(numeric16_program_fails(replacement),
            "replacement failure remains a failure")) return 1;
    Numeric16Failure original_failure = numeric16_failure(original);
    if (!expect(!numeric16_failure_same(replacement, original_failure),
            "shrink must not accept a different failure signature")) return 1;
    Numeric16Program reduced = numeric16_shrink(original);
    bool has_add = false;
    bool has_cadd = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric16Op.ADD) has_add = true;
        if (reduced.ops[i].op == Numeric16Op.CADD) has_cadd = true;
    }
    numeric16_mutation = 0;
    if (!expect(has_add && has_cadd, "shrink preserves the original operation mix")) {
        return 1;
    }
    return 0;
}

fn int numeric16_run_program(Numeric16Program program) {
    if (!numeric16_program_fails(program)) return 0;
    Numeric16Program reduced = numeric16_shrink(program);
    io::eprintn(numeric16_source(&reduced));
    return 1;
}

fn int numeric16_oracle_main() {
    defer (void)cleanup_temp_dir();
    reset_temp_dir() ?? unreachable();
    if (numeric16_reference_selftest() != 0) return 1;
    if (numeric16_mutation_selftest() != 0) return 1;
    if (numeric16_shrink_selftest() != 0) return 1;
    if (numeric16_shrink_signature_selftest() != 0) return 1;
    numeric16_coverage_reset();
    for (int index = 0; index < 64; index++) {
        Numeric16Program program = numeric16_valid_program(index);
        ulong faults_before = numeric16_coverage.faults;
        if (numeric16_run_program(program) != 0) return 1;
        if (numeric16_coverage.faults != faults_before) {
            io::eprintfn("numeric16 valid index=%d unexpectedly faulted", index);
            io::eprintn(numeric16_source(&program));
            return 1;
        }
    }
    for (int index = 0; index < 64; index++) {
        Numeric16Program program = numeric16_fault_program(index % 37);
        if (index >= 37) numeric16_randomize_fault(&program, (ulong)index);
        ulong valid_before = numeric16_coverage.valid;
        if (numeric16_run_program(program) != 0) return 1;
        if (numeric16_coverage.valid != valid_before) {
            io::eprintfn("numeric16 fault index=%d unexpectedly succeeded", index);
            io::eprintn(numeric16_source(&program));
            return 1;
        }
    }
    numeric16_coverage_print();
    if (!numeric16_coverage_ok()) return 1;
    io::printn("NUMERIC16_ORACLE OK (128 programs)");
    return 0;
}
