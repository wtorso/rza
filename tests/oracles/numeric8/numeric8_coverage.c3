module rza_tests;

import std::io;

struct Numeric8Coverage {
    ulong[NUMERIC8_OP_COUNT] success_i8;
    ulong[NUMERIC8_OP_COUNT] success_u8;
    ulong[NUMERIC8_OP_COUNT] fault_i8;
    ulong[NUMERIC8_OP_COUNT] fault_u8;
    ulong[NUMERIC8_OP_COUNT] immediate_i8;
    ulong[NUMERIC8_OP_COUNT] immediate_u8;
    ulong[NUMERIC8_OP_COUNT] register_i8;
    ulong[NUMERIC8_OP_COUNT] register_u8;
    ulong[NUMERIC8_OP_COUNT] dirty_immediate_i8;
    ulong[NUMERIC8_OP_COUNT] dirty_immediate_u8;
    ulong[NUMERIC8_OP_COUNT] dirty_register_i8;
    ulong[NUMERIC8_OP_COUNT] dirty_register_u8;
    ulong valid;
    ulong faults;
    ulong checked;
    ulong division;
    ulong shifts;
    ulong bounds;
    ulong dead;
}

Numeric8Coverage numeric8_coverage;

fn void numeric8_coverage_reset() {
    numeric8_coverage = {};
}

fn ulong numeric8_success_get(Numeric8Op op, Numeric8Type type) {
    return type == Numeric8Type.I8
        ? numeric8_coverage.success_i8[(int)op]
        : numeric8_coverage.success_u8[(int)op];
}

fn ulong numeric8_fault_get(Numeric8Op op, Numeric8Type type) {
    return type == Numeric8Type.I8
        ? numeric8_coverage.fault_i8[(int)op]
        : numeric8_coverage.fault_u8[(int)op];
}

fn ulong numeric8_form_get(Numeric8Op op, Numeric8Type type, bool immediate) {
    if (type == Numeric8Type.I8) {
        return immediate ? numeric8_coverage.immediate_i8[(int)op]
            : numeric8_coverage.register_i8[(int)op];
    }
    return immediate ? numeric8_coverage.immediate_u8[(int)op]
        : numeric8_coverage.register_u8[(int)op];
}

fn ulong numeric8_dirty_get(Numeric8Op op, Numeric8Type type, bool immediate) {
    if (type == Numeric8Type.I8) {
        return immediate ? numeric8_coverage.dirty_immediate_i8[(int)op]
            : numeric8_coverage.dirty_register_i8[(int)op];
    }
    return immediate ? numeric8_coverage.dirty_immediate_u8[(int)op]
        : numeric8_coverage.dirty_register_u8[(int)op];
}

fn void numeric8_cover_success(Numeric8Op op, Numeric8Type type,
        bool immediate, bool dirty) {
    if (type == Numeric8Type.I8) {
        numeric8_coverage.success_i8[(int)op]++;
        if (immediate) {
            numeric8_coverage.immediate_i8[(int)op]++;
            if (dirty) numeric8_coverage.dirty_immediate_i8[(int)op]++;
        } else {
            numeric8_coverage.register_i8[(int)op]++;
            if (dirty) numeric8_coverage.dirty_register_i8[(int)op]++;
        }
        return;
    }
    numeric8_coverage.success_u8[(int)op]++;
    if (immediate) {
        numeric8_coverage.immediate_u8[(int)op]++;
        if (dirty) numeric8_coverage.dirty_immediate_u8[(int)op]++;
    } else {
        numeric8_coverage.register_u8[(int)op]++;
        if (dirty) numeric8_coverage.dirty_register_u8[(int)op]++;
    }
}

fn void numeric8_cover_fault(Numeric8Op op, Numeric8Type type, Numeric8Fault failure) {
    if (type == Numeric8Type.I8) {
        numeric8_coverage.fault_i8[(int)op]++;
    } else {
        numeric8_coverage.fault_u8[(int)op]++;
    }
    numeric8_coverage.faults++;
    switch (failure) {
        case Numeric8Fault.ARITHMETIC: numeric8_coverage.checked++;
        case Numeric8Fault.DIVISION: numeric8_coverage.division++;
        case Numeric8Fault.SHIFT: numeric8_coverage.shifts++;
        case Numeric8Fault.BOUNDS: numeric8_coverage.bounds++;
        case Numeric8Fault.DEAD: numeric8_coverage.dead++;
        default: unreachable();
    }
}

fn bool numeric8_legal(Numeric8Op op, Numeric8Type type) {
    if (op == Numeric8Op.SLT || op == Numeric8Op.SHR) return type == Numeric8Type.I8;
    if (op == Numeric8Op.ULT) return type == Numeric8Type.U8;
    return true;
}

fn int numeric8_required_faults(Numeric8Op op, Numeric8Type type) {
    if (!numeric8_legal(op, type)) return 0;
    switch (op) {
        case Numeric8Op.CADD: case Numeric8Op.CSUB: case Numeric8Op.CMUL:
        case Numeric8Op.DIV: case Numeric8Op.MOD:
            return type == Numeric8Type.I8 ? 2 : 1;
        case Numeric8Op.CINC: case Numeric8Op.CDEC:
            return 1;
        case Numeric8Op.SHL: case Numeric8Op.SHR: case Numeric8Op.USHR:
        case Numeric8Op.LOAD: case Numeric8Op.STORE:
            return 2;
        default:
            return 0;
    }
}

fn bool numeric8_form_coverage_ok(Numeric8Op op, Numeric8Type type) {
    if (op == Numeric8Op.MOV_IMM) {
        return numeric8_form_get(op, type, true) > 0;
    }
    if (op == Numeric8Op.MOV_REG || op == Numeric8Op.INC ||
            op == Numeric8Op.DEC || op == Numeric8Op.CINC ||
            op == Numeric8Op.CDEC) {
        return numeric8_dirty_get(op, type, false) > 0;
    }
    return numeric8_form_get(op, type, true) > 0 &&
        numeric8_form_get(op, type, false) > 0 &&
        numeric8_dirty_get(op, type, true) > 0 &&
        numeric8_dirty_get(op, type, false) > 0;
}

fn bool numeric8_coverage_ok() {
    if (!expect(numeric8_coverage.valid == 64 && numeric8_coverage.faults == 64,
            "numeric8 oracle needs exactly 64 valid and 64 fault programs")) return false;
    for (int op = 0; op < NUMERIC8_OP_COUNT; op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric8Type type = (Numeric8Type)raw_type;
            if (!numeric8_legal((Numeric8Op)op, type)) continue;
            if (!expect(numeric8_success_get((Numeric8Op)op, type) > 0,
                    "numeric8 every legal op/type needs success coverage")) return false;
            int required = numeric8_required_faults((Numeric8Op)op, type);
            if (!expect((int)numeric8_fault_get((Numeric8Op)op, type) >= required,
                    "numeric8 per-op/type fault coverage")) return false;
            if (!expect(numeric8_form_coverage_ok((Numeric8Op)op, type),
                    "numeric8 operand forms and dirty inputs need explicit coverage")) {
                return false;
            }
        }
    }
    return true;
}

fn void numeric8_coverage_print() {
    io::printfn("NUMERIC8_COVERAGE valid=%d fault=%d checked=%d division=%d",
        numeric8_coverage.valid, numeric8_coverage.faults,
        numeric8_coverage.checked, numeric8_coverage.division);
    io::printfn("NUMERIC8_FAULTS shifts=%d bounds=%d dead=%d",
        numeric8_coverage.shifts, numeric8_coverage.bounds, numeric8_coverage.dead);
}
