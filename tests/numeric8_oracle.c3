module rza_tests;

import std::core::dstring;
import std::io;

const int NUMERIC8_PROGRAM_OPS_MAX = 16;

struct Numeric8Instruction {
    Numeric8Op op;
    Numeric8Type type;
    int dst;
    int left;
    int right;
    long value;
    bool immediate_rhs;
    bool dynamic_offset;
}

struct Numeric8Program {
    Numeric8Instruction[NUMERIC8_PROGRAM_OPS_MAX] ops;
    int len;
}

struct Numeric8Expected {
    DString output;
    DString errors;
    int status;
}

fn void numeric8_push(Numeric8Program* program, Numeric8Instruction ins) {
    assert(program.len >= 0 && program.len < NUMERIC8_PROGRAM_OPS_MAX);
    program.ops[program.len] = ins;
    program.len++;
}

fn void numeric8_push_legacy(Numeric8Program* program, int dst, long value) {
    numeric8_push(program, {
        .op = Numeric8Op.LEGACY_MOV, .dst = dst, .value = value,
    });
}

fn Numeric8Program numeric8_make_program(Numeric8Op op, Numeric8Type type,
        long left, long right, bool immediate, int fault_mode) {
    Numeric8Program program = {};
    numeric8_push_legacy(&program, 0, left);
    numeric8_push_legacy(&program, 1, right);
    if (op == Numeric8Op.LOAD) {
        numeric8_push(&program, { .op = Numeric8Op.SETUP_STORE, .left = 0 });
    }
    if (fault_mode == 2) numeric8_push(&program, { .op = Numeric8Op.DECAY });
    Numeric8Instruction target = {
        .op = op, .type = type, .dst = 2, .left = 0, .right = 1,
        .value = right, .immediate_rhs = immediate,
        .dynamic_offset = fault_mode == 1,
    };
    if (op == Numeric8Op.MOV_IMM) target.value = left;
    if (op == Numeric8Op.INC || op == Numeric8Op.DEC ||
            op == Numeric8Op.CINC || op == Numeric8Op.CDEC) {
        target.dst = 0;
    }
    numeric8_push(&program, target);
    if (op == Numeric8Op.STORE) {
        numeric8_push(&program, {
            .op = Numeric8Op.LOAD, .type = type, .dst = 2, .right = 0,
        });
    }
    numeric8_push(&program, {
        .op = Numeric8Op.PRINT, .left = target.dst,
    });
    numeric8_push(&program, { .op = Numeric8Op.RET });
    return program;
}

fn int numeric8_fault_line(int index) {
    assert(index >= 0 && index < NUMERIC8_PROGRAM_OPS_MAX);
    return index + 4;
}

fn bool numeric8_memory_fault(Numeric8Instruction ins, long offset,
        bool alive, DString* errors, int line) {
    if (!alive) {
        errors.appendf("FAULT line %d: dead mediator raw_m\n", line);
        numeric8_cover_fault(ins.op, ins.type, Numeric8Fault.DEAD);
        return true;
    }
    if (offset < 0 || offset >= 2) {
        errors.appendf("FAULT line %d: out of bounds raw_m\n", line);
        numeric8_cover_fault(ins.op, ins.type, Numeric8Fault.BOUNDS);
        return true;
    }
    return false;
}

fn bool numeric8_immediate_form(Numeric8Instruction ins) {
    if (ins.op == Numeric8Op.MOV_IMM) return true;
    if (ins.op == Numeric8Op.MOV_REG || ins.op == Numeric8Op.INC ||
            ins.op == Numeric8Op.DEC || ins.op == Numeric8Op.CINC ||
            ins.op == Numeric8Op.CDEC) return false;
    if (ins.op == Numeric8Op.LOAD || ins.op == Numeric8Op.STORE) {
        return !ins.dynamic_offset;
    }
    return ins.immediate_rhs;
}

fn bool numeric8_dirty_input(Numeric8Instruction ins, long left, long right) {
    if (ins.op == Numeric8Op.MOV_IMM) return false;
    if (((ulong)left & ~0xffUL) != 0) return true;
    bool shift = ins.op == Numeric8Op.SHL || ins.op == Numeric8Op.SHR ||
        ins.op == Numeric8Op.USHR;
    bool unary = ins.op == Numeric8Op.INC || ins.op == Numeric8Op.DEC ||
        ins.op == Numeric8Op.CINC || ins.op == Numeric8Op.CDEC;
    if (ins.op == Numeric8Op.MOV_REG || ins.op == Numeric8Op.LOAD ||
            ins.op == Numeric8Op.STORE || shift || unary || ins.immediate_rhs) {
        return false;
    }
    return ((ulong)right & ~0xffUL) != 0;
}

fn void numeric8_cover_execution(Numeric8Instruction ins, long left, long right) {
    numeric8_cover_success(ins.op, ins.type, numeric8_immediate_form(ins),
        numeric8_dirty_input(ins, left, right));
}

fn Numeric8Expected numeric8_reference(Numeric8Program* program) {
    long[16] regs = {};
    char[2] cell = {};
    bool alive = true;
    DString output = dstring::temp();
    DString errors = dstring::temp();
    for (int index = 0; index < program.len; index++) {
        Numeric8Instruction ins = program.ops[index];
        int line = numeric8_fault_line(index);
        if (ins.op == Numeric8Op.RET) {
            numeric8_coverage.valid++;
            return { output, errors, 0 };
        }
        if (ins.op == Numeric8Op.DECAY) {
            alive = false;
            continue;
        }
        if (ins.op == Numeric8Op.PRINT) {
            output.appendf("%d\n", regs[ins.left]);
            continue;
        }
        if (ins.op == Numeric8Op.LEGACY_MOV) {
            regs[ins.dst] = ins.value;
            continue;
        }
        if (ins.op == Numeric8Op.SETUP_STORE) {
            cell[0] = (char)(regs[ins.left] & 0xff);
            continue;
        }
        long left = regs[ins.left];
        long right = ins.immediate_rhs ? ins.value : regs[ins.right];
        if (ins.op == Numeric8Op.LOAD || ins.op == Numeric8Op.STORE) {
            long offset = ins.dynamic_offset ? regs[ins.right] : 0;
            if (numeric8_memory_fault(ins, offset, alive, &errors, line)) {
                return { output, errors, 1 };
            }
            if (ins.op == Numeric8Op.LOAD) {
                regs[ins.dst] = numeric8_normalize(ins.type, (ulong)cell[(sz)offset]);
            } else {
                cell[(sz)offset] = (char)(regs[ins.left] & 0xff);
            }
            numeric8_cover_execution(ins, left, right);
            continue;
        }
        if (ins.op == Numeric8Op.MOV_IMM) {
            regs[ins.dst] = numeric8_normalize(ins.type, (ulong)ins.value);
        } else if (ins.op == Numeric8Op.MOV_REG) {
            regs[ins.dst] = numeric8_normalize(ins.type, (ulong)left);
        } else {
            Numeric8Fault failure;
            long value = numeric8_evaluate(ins.op, ins.type, left, right, &failure);
            if (failure != Numeric8Fault.NONE) {
                String reason = failure == Numeric8Fault.ARITHMETIC ? "arithmetic overflow"
                    : failure == Numeric8Fault.DIVISION ? "division" : "shift";
                errors.appendf("FAULT line %d: %s\n", line, reason);
                numeric8_cover_fault(ins.op, ins.type, failure);
                return { output, errors, 1 };
            }
            regs[ins.dst] = value;
        }
        numeric8_cover_execution(ins, left, right);
    }
    unreachable("numeric8 reference requires ret");
}

fn String numeric8_type_name(Numeric8Type type) {
    return type == Numeric8Type.I8 ? "i8" : "u8";
}

fn String numeric8_op_name(Numeric8Op op) {
    switch (op) {
        case Numeric8Op.MOV_IMM: case Numeric8Op.MOV_REG: return "mov";
        case Numeric8Op.LOAD: return "load";
        case Numeric8Op.STORE: return "store";
        case Numeric8Op.ADD: return "add";
        case Numeric8Op.SUB: return "sub";
        case Numeric8Op.MUL: return "mul";
        case Numeric8Op.INC: return "inc";
        case Numeric8Op.DEC: return "dec";
        case Numeric8Op.CADD: return "cadd";
        case Numeric8Op.CSUB: return "csub";
        case Numeric8Op.CMUL: return "cmul";
        case Numeric8Op.CINC: return "cinc";
        case Numeric8Op.CDEC: return "cdec";
        case Numeric8Op.AND: return "and";
        case Numeric8Op.OR: return "or";
        case Numeric8Op.XOR: return "xor";
        case Numeric8Op.SLT: return "slt";
        case Numeric8Op.ULT: return "ult";
        case Numeric8Op.DIV: return "div";
        case Numeric8Op.MOD: return "mod";
        case Numeric8Op.SHL: return "shl";
        case Numeric8Op.SHR: return "shr";
        case Numeric8Op.USHR: return "ushr";
        default: unreachable("not a typed numeric8 opcode");
    }
}

fn void numeric8_emit_typed(DString* source, Numeric8Instruction ins) {
    String op = numeric8_op_name(ins.op);
    String type = numeric8_type_name(ins.type);
    if (ins.op == Numeric8Op.MOV_IMM) {
        source.appendf("mov.%s %%r%d, 0x%02x\n", type, ins.dst,
            (uint)ins.value & 0xff);
        return;
    }
    if (ins.op == Numeric8Op.MOV_REG) {
        source.appendf("mov.%s %%r%d, %%r%d\n", type, ins.dst, ins.left);
        return;
    }
    if (ins.op == Numeric8Op.LOAD || ins.op == Numeric8Op.STORE) {
        DString offset = dstring::temp();
        if (ins.dynamic_offset) {
            offset.appendf("%%r%d", ins.right);
        } else {
            offset.append("0");
        }
        if (ins.op == Numeric8Op.LOAD) {
            source.appendf("load.%s %%r%d, [raw_m + %s]\n", type, ins.dst,
                offset.str_view());
        } else {
            source.appendf("store.%s [raw_m + %s], %%r%d\n", type,
                offset.str_view(), ins.left);
        }
        return;
    }
    if (ins.op == Numeric8Op.INC || ins.op == Numeric8Op.DEC ||
            ins.op == Numeric8Op.CINC || ins.op == Numeric8Op.CDEC) {
        source.appendf("%s.%s %%r%d\n", op, type, ins.dst);
        return;
    }
    source.appendf("%s.%s %%r%d, %%r%d, ", op, type, ins.dst, ins.left);
    if (!ins.immediate_rhs) {
        source.appendf("%%r%d\n", ins.right);
        return;
    }
    bool shift = ins.op == Numeric8Op.SHL || ins.op == Numeric8Op.SHR ||
        ins.op == Numeric8Op.USHR;
    if (shift) {
        source.appendf("%d\n", ins.value);
    } else {
        source.appendf("0x%02x\n", (uint)ins.value & 0xff);
    }
}

fn String numeric8_source(Numeric8Program* program) {
    DString source = dstring::temp("cav main, field\nres raw, main, 2\n"
        "med raw_m, raw, main\n");
    for (int index = 0; index < program.len; index++) {
        Numeric8Instruction ins = program.ops[index];
        switch (ins.op) {
            case Numeric8Op.LEGACY_MOV:
                source.appendf("mov %%r%d, %d\n", ins.dst, ins.value);
            case Numeric8Op.SETUP_STORE:
                source.appendf("storeb [raw_m + 0], %%r%d\n", ins.left);
            case Numeric8Op.PRINT:
                source.appendf("print %%r%d\n", ins.left);
            case Numeric8Op.DECAY:
                source.append("decay main\n");
            case Numeric8Op.RET:
                source.append("ret\n");
            default:
                numeric8_emit_typed(&source, ins);
        }
    }
    return source.str_view();
}

fn int numeric8_valid_forms(Numeric8Op op) {
    if (op == Numeric8Op.MOV_IMM || op == Numeric8Op.MOV_REG ||
            op == Numeric8Op.INC || op == Numeric8Op.DEC ||
            op == Numeric8Op.CINC || op == Numeric8Op.CDEC) return 1;
    return 2;
}

fn Numeric8Instruction numeric8_valid_operation(int slot) {
    assert(slot >= 0 && slot < 78);
    Numeric8Instruction selected = { .dst = 2, .left = 0, .right = 1 };
    int cell = 0;
    bool found = false;
    for (int raw_op = 0; raw_op < NUMERIC8_OP_COUNT; raw_op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric8Op op = (Numeric8Op)raw_op;
            Numeric8Type type = (Numeric8Type)raw_type;
            if (!numeric8_legal(op, type)) continue;
            int forms = numeric8_valid_forms(op);
            for (int form = 0; form < forms; form++) {
                if (cell == slot) {
                    selected.op = op;
                    selected.type = type;
                    selected.immediate_rhs = forms == 2 ? form == 0
                        : op == Numeric8Op.MOV_IMM;
                    selected.dynamic_offset = (op == Numeric8Op.LOAD ||
                        op == Numeric8Op.STORE) && form == 1;
                    found = true;
                }
                cell++;
            }
        }
    }
    assert(found && cell == 78);
    return selected;
}

fn void numeric8_valid_values(Numeric8Instruction* ins, int slot,
        long* left, long* right) {
    *left = (long)((slot * 37) & 0xff) | (long)((slot % 3 + 1) * 256);
    *right = (long)((slot * 11) & 0xff) | (long)((slot % 2 + 1) * 512);
    if (ins.op == Numeric8Op.CADD || ins.op == Numeric8Op.CMUL) {
        *left = 0x102;
        *right = 0x203;
    }
    if (ins.op == Numeric8Op.CSUB) {
        *left = ins.type == Numeric8Type.U8 ? 0x103 : 0x102;
        *right = ins.type == Numeric8Type.U8 ? 0x202 : 0x203;
    }
    if (ins.op == Numeric8Op.CINC) *left = 0x100;
    if (ins.op == Numeric8Op.CDEC) {
        *left = ins.type == Numeric8Type.U8 ? 0x101 : 0x100;
    }
    if (ins.op == Numeric8Op.DIV || ins.op == Numeric8Op.MOD) {
        *left = 0x106;
        *right = 0x202;
    }
    bool shift = ins.op == Numeric8Op.SHL || ins.op == Numeric8Op.SHR ||
        ins.op == Numeric8Op.USHR;
    if (shift) {
        *left = 0x180;
        *right = 1;
    }
    if (ins.op == Numeric8Op.LOAD || ins.op == Numeric8Op.STORE) *right = 0;
    ins.value = ins.immediate_rhs ? *right & 0xff : *right;
    if (ins.op == Numeric8Op.MOV_IMM) ins.value = *left & 0xff;
}

fn void numeric8_valid_slot(Numeric8Program* program, int slot) {
    Numeric8Instruction target = numeric8_valid_operation(slot);
    long left;
    long right;
    numeric8_valid_values(&target, slot, &left, &right);
    numeric8_push_legacy(program, 0, left);
    numeric8_push_legacy(program, 1, right);
    if (target.op == Numeric8Op.LOAD) {
        numeric8_push(program, { .op = Numeric8Op.SETUP_STORE, .left = 0 });
    }
    if (target.op == Numeric8Op.INC || target.op == Numeric8Op.DEC ||
            target.op == Numeric8Op.CINC || target.op == Numeric8Op.CDEC) {
        target.dst = 0;
    }
    numeric8_push(program, target);
    if (target.op == Numeric8Op.STORE) {
        numeric8_push(program, {
            .op = Numeric8Op.LOAD, .type = target.type, .dst = 2,
            .left = 0, .right = 1, .dynamic_offset = target.dynamic_offset,
        });
    }
    numeric8_push(program, { .op = Numeric8Op.PRINT, .left = target.dst });
}

fn Numeric8Program numeric8_valid_program(int index) {
    assert(index >= 0 && index < 64);
    Numeric8Program program = {};
    int slot = index * 2;
    numeric8_valid_slot(&program, slot % 78);
    numeric8_valid_slot(&program, (slot + 1) % 78);
    numeric8_push(&program, { .op = Numeric8Op.RET });
    return program;
}

fn Numeric8Program numeric8_fault_checked(int index) {
    Numeric8Op[] ops = {
        Numeric8Op.CADD, Numeric8Op.CADD, Numeric8Op.CSUB, Numeric8Op.CSUB,
        Numeric8Op.CMUL, Numeric8Op.CMUL, Numeric8Op.CADD, Numeric8Op.CSUB,
        Numeric8Op.CMUL, Numeric8Op.CINC, Numeric8Op.CDEC,
        Numeric8Op.CINC, Numeric8Op.CDEC,
    };
    Numeric8Type[] types = {
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.I8,
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.U8, Numeric8Type.U8,
        Numeric8Type.U8, Numeric8Type.I8, Numeric8Type.I8,
        Numeric8Type.U8, Numeric8Type.U8,
    };
    long[] left = { 127, -128, 127, -128, 64, -128, 255, 0, 255, 127, -128, 255, 0 };
    long[] right = { 1, -1, -1, 1, 2, 2, 1, 1, 2, 0, 0, 0, 0 };
    assert(index >= 0 && index < 13);
    return numeric8_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric8Program numeric8_fault_division(int index) {
    Numeric8Op[] ops = {
        Numeric8Op.DIV, Numeric8Op.DIV, Numeric8Op.MOD,
        Numeric8Op.MOD, Numeric8Op.DIV, Numeric8Op.MOD,
    };
    Numeric8Type[] types = {
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.I8,
        Numeric8Type.I8, Numeric8Type.U8, Numeric8Type.U8,
    };
    long[] left = { 1, -128, 1, -128, 1, 1 };
    long[] right = { 0, -1, 0, -1, 0, 0 };
    assert(index >= 0 && index < 6);
    return numeric8_make_program(ops[index], types[index], left[index], right[index],
        index % 2 == 0, 0);
}

fn Numeric8Program numeric8_fault_shift(int index) {
    Numeric8Op[] ops = {
        Numeric8Op.SHL, Numeric8Op.SHL, Numeric8Op.SHL, Numeric8Op.SHL,
        Numeric8Op.SHR, Numeric8Op.SHR, Numeric8Op.USHR, Numeric8Op.USHR,
        Numeric8Op.USHR, Numeric8Op.USHR,
    };
    Numeric8Type[] types = {
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.U8, Numeric8Type.U8,
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.I8,
        Numeric8Type.U8, Numeric8Type.U8,
    };
    assert(index >= 0 && index < 10);
    long right = index % 2 == 0 ? -1 : 8;
    return numeric8_make_program(ops[index], types[index], 1, right, true, 0);
}

fn Numeric8Program numeric8_fault_memory(int index) {
    Numeric8Op op = index < 4 ? Numeric8Op.LOAD : Numeric8Op.STORE;
    Numeric8Type[] types = {
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.U8, Numeric8Type.U8,
        Numeric8Type.I8, Numeric8Type.I8, Numeric8Type.U8, Numeric8Type.U8,
    };
    assert(index >= 0 && index < 8);
    int mode = index % 2 == 0 ? 1 : 2;
    return numeric8_make_program(op, types[index], 128, 2, false, mode);
}

fn Numeric8Program numeric8_fault_program(int index) {
    if (index < 13) return numeric8_fault_checked(index);
    if (index < 19) return numeric8_fault_division(index - 13);
    if (index < 29) return numeric8_fault_shift(index - 19);
    return numeric8_fault_memory(index - 29);
}

struct Numeric8Rng {
    ulong state;
}

fn ulong Numeric8Rng.next(&self) {
    ulong x = self.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    self.state = x;
    return x * 2685821657736338717;
}

fn void numeric8_randomize_fault(Numeric8Program* program, ulong seed) {
    Numeric8Rng rng = { seed ^ 0x9e3779b97f4a7c15 };
    ulong upper_left = rng.next() & 0x7fffffffffffff00;
    ulong left = (ulong)program.ops[0].value & 0xff;
    program.ops[0].value = (long)(left | upper_left);
    for (int index = 0; index < program.len; index++) {
        Numeric8Instruction* target = &program.ops[index];
        if (target.op >= Numeric8Op.LEGACY_MOV) continue;
        bool shift = target.op == Numeric8Op.SHL || target.op == Numeric8Op.SHR ||
            target.op == Numeric8Op.USHR;
        if (!shift && !target.dynamic_offset) {
            ulong upper = rng.next() & 0x7fffffffffffff00;
            ulong right = (ulong)program.ops[1].value & 0xff;
            program.ops[1].value = (long)(right | upper);
        }
        if (rng.next() % 2 == 0) target.immediate_rhs = !target.immediate_rhs;
        break;
    }
}

ulong numeric8_attempt;
int numeric8_mutation;
char[1048576] numeric8_generated_buf;

fn String numeric8_replace(String text, String needle, String replacement,
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

fn void numeric8_mutate_generated(String path) {
    if (numeric8_mutation == 0) return;
    char[] data = read_file(path, numeric8_generated_buf[..]) ?? unreachable();
    String from = numeric8_mutation == 1
        ? "rez_i8_from_bits" : "if (rez_i8_cadd(";
    String to = numeric8_mutation == 1
        ? "rez_u8_from_bits" : "if (false && rez_i8_cadd(";
    bool changed;
    String mutated = numeric8_replace((String)data, from, to, &changed);
    if (!changed) return;
    write_file(path, mutated) ?? unreachable();
}

fn bool numeric8_program_fails(Numeric8Program program) {
    Numeric8Expected expected = numeric8_reference(&program);
    String source = numeric8_source(&program);
    assert(numeric8_attempt < 1000000);
    String name = string::tformat("numeric8-%d.rza", numeric8_attempt);
    numeric8_attempt++;
    String path = temp_path(name);
    write_file(path, source) ?? unreachable();
    String generated = string::tformat("%s.c", path);
    ProcessResult emitted = run_simple({
        compiler_path(), path, "--emit-c", "-o", generated,
    }) ?? unreachable();
    if (emitted.status != 0 || emitted.stdout_text.len != 0 ||
            emitted.stderr_text.len != 0) return true;
    numeric8_mutate_generated(generated);
    String executable = string::tformat("%s.exe", path);
    ProcessResult compiled = compile_c(generated, executable) ?? unreachable();
    if (compiled.status != 0 || compiled.stderr_text.len != 0) return true;
    ProcessResult runtime = run_program({ executable }) ?? unreachable();
    bool mismatch = runtime.status != expected.status ||
        normalize_lines(runtime.stdout_text) != normalize_lines(expected.output.str_view()) ||
        normalize_lines(runtime.stderr_text) != normalize_lines(expected.errors.str_view());
    if (mismatch) {
        io::eprintfn("numeric8 expected status=%d stdout=%s stderr=%s",
            expected.status, expected.output.str_view(), expected.errors.str_view());
        print_result(runtime);
    }
    return mismatch;
}

fn Numeric8Program numeric8_remove(Numeric8Program program, int index) {
    assert(index >= 0 && index < program.len);
    for (int i = index + 1; i < program.len; i++) program.ops[i - 1] = program.ops[i];
    program.len--;
    return program;
}

fn Numeric8Program numeric8_shrink(Numeric8Program world) {
    assert(numeric8_program_fails(world));
    Numeric8Program best = world;
    for (int round = 0; round < 16; round++) {
        bool changed = false;
        for (int index = 0; index < best.len; index++) {
            Numeric8Op op = best.ops[index].op;
            if (op == Numeric8Op.PRINT || op == Numeric8Op.RET) continue;
            Numeric8Program candidate = numeric8_remove(best, index);
            if (numeric8_program_fails(candidate)) {
                best = candidate;
                changed = true;
            }
        }
        if (!changed) break;
    }
    assert(numeric8_program_fails(best));
    return best;
}

fn int numeric8_mutation_selftest() {
    Numeric8Program load = numeric8_make_program(Numeric8Op.LOAD,
        Numeric8Type.I8, 128, 0, false, 0);
    if (!expect(!numeric8_program_fails(load), "numeric8 load fixture")) return 1;
    numeric8_mutation = 1;
    if (!expect(numeric8_program_fails(load),
            "oracle detects wrong i8 sign extension")) return 1;
    numeric8_mutation = 0;
    Numeric8Program checked = numeric8_make_program(Numeric8Op.CADD,
        Numeric8Type.I8, 127, 1, true, 0);
    if (!expect(!numeric8_program_fails(checked), "numeric8 checked fixture")) return 1;
    numeric8_mutation = 2;
    if (!expect(numeric8_program_fails(checked),
            "oracle detects removed checked-overflow guard")) return 1;
    numeric8_mutation = 0;
    return 0;
}

fn int numeric8_shrink_selftest() {
    Numeric8Program program = {};
    numeric8_push_legacy(&program, 0, 128);
    numeric8_push(&program, { .op = Numeric8Op.SETUP_STORE, .left = 0 });
    numeric8_push_legacy(&program, 1, 1);
    numeric8_push(&program, {
        .op = Numeric8Op.ADD, .type = Numeric8Type.I8, .dst = 1,
        .left = 1, .right = 1, .value = 1, .immediate_rhs = true,
    });
    numeric8_push(&program, {
        .op = Numeric8Op.LOAD, .type = Numeric8Type.I8, .dst = 2, .left = 0,
    });
    numeric8_push(&program, { .op = Numeric8Op.PRINT, .left = 2 });
    numeric8_push(&program, { .op = Numeric8Op.RET });
    numeric8_mutation = 1;
    if (!expect(numeric8_program_fails(program), "numeric8 shrink fixture")) return 1;
    Numeric8Program reduced = numeric8_shrink(program);
    bool has_add = false;
    for (int i = 0; i < reduced.len; i++) {
        if (reduced.ops[i].op == Numeric8Op.ADD) has_add = true;
    }
    if (!expect(reduced.len == 5 && !has_add && numeric8_program_fails(reduced),
            "numeric8 shrink removes irrelevant instructions without stale artifacts")) {
        return 1;
    }
    numeric8_mutation = 0;
    return 0;
}

fn int numeric8_run_program(Numeric8Program program) {
    if (!numeric8_program_fails(program)) return 0;
    Numeric8Program reduced = numeric8_shrink(program);
    io::eprintn(numeric8_source(&reduced));
    return 1;
}

fn int numeric8_oracle_main() {
    defer (void)cleanup_temp_dir();
    reset_temp_dir() ?? unreachable();
    if (numeric8_reference_selftest() != 0) return 1;
    if (numeric8_mutation_selftest() != 0) return 1;
    if (numeric8_shrink_selftest() != 0) return 1;
    numeric8_coverage_reset();
    for (int index = 0; index < 64; index++) {
        Numeric8Program program = numeric8_valid_program(index);
        ulong faults_before = numeric8_coverage.faults;
        if (numeric8_run_program(program) != 0) return 1;
        if (numeric8_coverage.faults != faults_before) {
            io::eprintfn("numeric8 valid index=%d unexpectedly faulted", index);
            io::eprintn(numeric8_source(&program));
            return 1;
        }
    }
    for (int index = 0; index < 64; index++) {
        Numeric8Program program = numeric8_fault_program(index % 37);
        if (index >= 37) numeric8_randomize_fault(&program, (ulong)index);
        ulong valid_before = numeric8_coverage.valid;
        if (numeric8_run_program(program) != 0) return 1;
        if (numeric8_coverage.valid != valid_before) {
            io::eprintfn("numeric8 fault index=%d unexpectedly succeeded", index);
            io::eprintn(numeric8_source(&program));
            return 1;
        }
    }
    numeric8_coverage_print();
    if (!numeric8_coverage_ok()) return 1;
    io::printn("NUMERIC8_ORACLE OK (128 programs)");
    return 0;
}
