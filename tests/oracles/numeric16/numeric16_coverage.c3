module rza_tests;

import std::io;

struct Numeric16Coverage {
    ulong[NUMERIC16_OP_COUNT] success_i16;
    ulong[NUMERIC16_OP_COUNT] success_u16;
    ulong[NUMERIC16_OP_COUNT] fault_i16;
    ulong[NUMERIC16_OP_COUNT] fault_u16;
    ulong[NUMERIC16_OP_COUNT] immediate_i16;
    ulong[NUMERIC16_OP_COUNT] immediate_u16;
    ulong[NUMERIC16_OP_COUNT] register_i16;
    ulong[NUMERIC16_OP_COUNT] register_u16;
    ulong[NUMERIC16_OP_COUNT] dirty_immediate_i16;
    ulong[NUMERIC16_OP_COUNT] dirty_immediate_u16;
    ulong[NUMERIC16_OP_COUNT] dirty_register_i16;
    ulong[NUMERIC16_OP_COUNT] dirty_register_u16;
    ulong valid;
    ulong faults;
    ulong checked;
    ulong division;
    ulong shifts;
    ulong bounds;
    ulong dead;
}

Numeric16Coverage numeric16_coverage;

fn void numeric16_coverage_reset() {
    numeric16_coverage = {};
}

fn ulong numeric16_success_get(Numeric16Op op, Numeric16Type type) {
    return type == Numeric16Type.I16
        ? numeric16_coverage.success_i16[(int)op]
        : numeric16_coverage.success_u16[(int)op];
}

fn ulong numeric16_fault_get(Numeric16Op op, Numeric16Type type) {
    return type == Numeric16Type.I16
        ? numeric16_coverage.fault_i16[(int)op]
        : numeric16_coverage.fault_u16[(int)op];
}

fn ulong numeric16_form_get(Numeric16Op op, Numeric16Type type, bool immediate) {
    if (type == Numeric16Type.I16) {
        return immediate ? numeric16_coverage.immediate_i16[(int)op]
            : numeric16_coverage.register_i16[(int)op];
    }
    return immediate ? numeric16_coverage.immediate_u16[(int)op]
        : numeric16_coverage.register_u16[(int)op];
}

fn ulong numeric16_dirty_get(Numeric16Op op, Numeric16Type type, bool immediate) {
    if (type == Numeric16Type.I16) {
        return immediate ? numeric16_coverage.dirty_immediate_i16[(int)op]
            : numeric16_coverage.dirty_register_i16[(int)op];
    }
    return immediate ? numeric16_coverage.dirty_immediate_u16[(int)op]
        : numeric16_coverage.dirty_register_u16[(int)op];
}

fn void numeric16_cover_success(Numeric16Op op, Numeric16Type type,
        bool immediate, bool dirty) {
    if (type == Numeric16Type.I16) {
        numeric16_coverage.success_i16[(int)op]++;
        if (immediate) {
            numeric16_coverage.immediate_i16[(int)op]++;
            if (dirty) numeric16_coverage.dirty_immediate_i16[(int)op]++;
        } else {
            numeric16_coverage.register_i16[(int)op]++;
            if (dirty) numeric16_coverage.dirty_register_i16[(int)op]++;
        }
        return;
    }
    numeric16_coverage.success_u16[(int)op]++;
    if (immediate) {
        numeric16_coverage.immediate_u16[(int)op]++;
        if (dirty) numeric16_coverage.dirty_immediate_u16[(int)op]++;
    } else {
        numeric16_coverage.register_u16[(int)op]++;
        if (dirty) numeric16_coverage.dirty_register_u16[(int)op]++;
    }
}

fn void numeric16_cover_fault(Numeric16Op op, Numeric16Type type, Numeric16Fault failure) {
    if (type == Numeric16Type.I16) {
        numeric16_coverage.fault_i16[(int)op]++;
    } else {
        numeric16_coverage.fault_u16[(int)op]++;
    }
    numeric16_coverage.faults++;
    switch (failure) {
        case Numeric16Fault.ARITHMETIC: numeric16_coverage.checked++;
        case Numeric16Fault.DIVISION: numeric16_coverage.division++;
        case Numeric16Fault.SHIFT: numeric16_coverage.shifts++;
        case Numeric16Fault.BOUNDS: numeric16_coverage.bounds++;
        case Numeric16Fault.DEAD: numeric16_coverage.dead++;
        default: unreachable();
    }
}

fn bool numeric16_legal(Numeric16Op op, Numeric16Type type) {
    if (op == Numeric16Op.SLT || op == Numeric16Op.SHR) return type == Numeric16Type.I16;
    if (op == Numeric16Op.ULT) return type == Numeric16Type.U16;
    return true;
}

fn int numeric16_required_faults(Numeric16Op op, Numeric16Type type) {
    if (!numeric16_legal(op, type)) return 0;
    switch (op) {
        case Numeric16Op.CADD: case Numeric16Op.CSUB: case Numeric16Op.CMUL:
        case Numeric16Op.DIV: case Numeric16Op.MOD:
            return type == Numeric16Type.I16 ? 2 : 1;
        case Numeric16Op.CINC: case Numeric16Op.CDEC:
            return 1;
        case Numeric16Op.SHL: case Numeric16Op.SHR: case Numeric16Op.USHR:
        case Numeric16Op.LOAD: case Numeric16Op.STORE:
            return 2;
        default:
            return 0;
    }
}

fn bool numeric16_form_coverage_ok(Numeric16Op op, Numeric16Type type) {
    if (op == Numeric16Op.MOV_IMM) {
        return numeric16_form_get(op, type, true) > 0;
    }
    if (op == Numeric16Op.MOV_REG || op == Numeric16Op.INC ||
            op == Numeric16Op.DEC || op == Numeric16Op.CINC ||
            op == Numeric16Op.CDEC) {
        return numeric16_dirty_get(op, type, false) > 0;
    }
    return numeric16_form_get(op, type, true) > 0 &&
        numeric16_form_get(op, type, false) > 0 &&
        numeric16_dirty_get(op, type, true) > 0 &&
        numeric16_dirty_get(op, type, false) > 0;
}

fn bool numeric16_coverage_ok() {
    if (!expect(numeric16_coverage.valid == 64 && numeric16_coverage.faults == 64,
            "numeric16 oracle needs exactly 64 valid and 64 fault programs")) return false;
    for (int op = 0; op < NUMERIC16_OP_COUNT; op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric16Type type = (Numeric16Type)raw_type;
            if (!numeric16_legal((Numeric16Op)op, type)) continue;
            if (!expect(numeric16_success_get((Numeric16Op)op, type) > 0,
                    "numeric16 every legal op/type needs success coverage")) return false;
            int required = numeric16_required_faults((Numeric16Op)op, type);
            if (!expect((int)numeric16_fault_get((Numeric16Op)op, type) >= required,
                    "numeric16 per-op/type fault coverage")) return false;
            if (!expect(numeric16_form_coverage_ok((Numeric16Op)op, type),
                    "numeric16 operand forms and dirty inputs need explicit coverage")) {
                return false;
            }
        }
    }
    return true;
}

fn void numeric16_coverage_print() {
    io::printfn("NUMERIC16_COVERAGE valid=%d fault=%d checked=%d division=%d",
        numeric16_coverage.valid, numeric16_coverage.faults,
        numeric16_coverage.checked, numeric16_coverage.division);
    io::printfn("NUMERIC16_FAULTS shifts=%d bounds=%d dead=%d",
        numeric16_coverage.shifts, numeric16_coverage.bounds, numeric16_coverage.dead);
}
