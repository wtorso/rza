module rza_tests;

import std::io;

struct Numeric32Coverage {
    ulong[NUMERIC32_OP_COUNT] success_i32;
    ulong[NUMERIC32_OP_COUNT] success_u32;
    ulong[NUMERIC32_OP_COUNT] fault_i32;
    ulong[NUMERIC32_OP_COUNT] fault_u32;
    ulong[NUMERIC32_OP_COUNT] direct_fault_i32;
    ulong[NUMERIC32_OP_COUNT] direct_fault_u32;
    ulong[NUMERIC32_OP_COUNT] immediate_i32;
    ulong[NUMERIC32_OP_COUNT] immediate_u32;
    ulong[NUMERIC32_OP_COUNT] register_i32;
    ulong[NUMERIC32_OP_COUNT] register_u32;
    ulong[NUMERIC32_OP_COUNT] dirty_immediate_i32;
    ulong[NUMERIC32_OP_COUNT] dirty_immediate_u32;
    ulong[NUMERIC32_OP_COUNT] dirty_register_i32;
    ulong[NUMERIC32_OP_COUNT] dirty_register_u32;
    ulong valid;
    ulong faults;
    ulong checked;
    ulong division;
    ulong shifts;
    ulong bounds;
    ulong dead;
    ulong direct_faults;
    ulong direct_checked;
    ulong direct_division;
    ulong direct_shifts;
    ulong direct_bounds;
    ulong direct_dead;
    ulong shift33_immediate;
    ulong shift33_register;
}

Numeric32Coverage numeric32_coverage;
bool numeric32_direct_attribution;

fn void numeric32_coverage_reset() {
    numeric32_coverage = {};
    numeric32_direct_attribution = false;
}

fn void numeric32_cover_shift33(bool immediate) {
    if (immediate) {
        numeric32_coverage.shift33_immediate++;
    } else {
        numeric32_coverage.shift33_register++;
    }
}

fn ulong numeric32_success_get(Numeric32Op op, Numeric32Type type) {
    return type == Numeric32Type.I32
        ? numeric32_coverage.success_i32[(int)op]
        : numeric32_coverage.success_u32[(int)op];
}

fn ulong numeric32_fault_get(Numeric32Op op, Numeric32Type type) {
    return type == Numeric32Type.I32
        ? numeric32_coverage.fault_i32[(int)op]
        : numeric32_coverage.fault_u32[(int)op];
}

fn ulong numeric32_form_get(Numeric32Op op, Numeric32Type type, bool immediate) {
    if (type == Numeric32Type.I32) {
        return immediate ? numeric32_coverage.immediate_i32[(int)op]
            : numeric32_coverage.register_i32[(int)op];
    }
    return immediate ? numeric32_coverage.immediate_u32[(int)op]
        : numeric32_coverage.register_u32[(int)op];
}

fn ulong numeric32_dirty_get(Numeric32Op op, Numeric32Type type, bool immediate) {
    if (type == Numeric32Type.I32) {
        return immediate ? numeric32_coverage.dirty_immediate_i32[(int)op]
            : numeric32_coverage.dirty_register_i32[(int)op];
    }
    return immediate ? numeric32_coverage.dirty_immediate_u32[(int)op]
        : numeric32_coverage.dirty_register_u32[(int)op];
}

fn void numeric32_cover_success(Numeric32Op op, Numeric32Type type,
        bool immediate, bool dirty) {
    if (type == Numeric32Type.I32) {
        numeric32_coverage.success_i32[(int)op]++;
        if (immediate) {
            numeric32_coverage.immediate_i32[(int)op]++;
            if (dirty) numeric32_coverage.dirty_immediate_i32[(int)op]++;
        } else {
            numeric32_coverage.register_i32[(int)op]++;
            if (dirty) numeric32_coverage.dirty_register_i32[(int)op]++;
        }
        return;
    }
    numeric32_coverage.success_u32[(int)op]++;
    if (immediate) {
        numeric32_coverage.immediate_u32[(int)op]++;
        if (dirty) numeric32_coverage.dirty_immediate_u32[(int)op]++;
    } else {
        numeric32_coverage.register_u32[(int)op]++;
        if (dirty) numeric32_coverage.dirty_register_u32[(int)op]++;
    }
}

fn void numeric32_cover_fault(Numeric32Op op, Numeric32Type type, Numeric32Fault failure) {
    if (type == Numeric32Type.I32) {
        numeric32_coverage.fault_i32[(int)op]++;
        if (numeric32_direct_attribution) numeric32_coverage.direct_fault_i32[(int)op]++;
    } else {
        numeric32_coverage.fault_u32[(int)op]++;
        if (numeric32_direct_attribution) numeric32_coverage.direct_fault_u32[(int)op]++;
    }
    numeric32_coverage.faults++;
    if (numeric32_direct_attribution) numeric32_coverage.direct_faults++;
    switch (failure) {
        case Numeric32Fault.ARITHMETIC:
            numeric32_coverage.checked++;
            if (numeric32_direct_attribution) numeric32_coverage.direct_checked++;
        case Numeric32Fault.DIVISION:
            numeric32_coverage.division++;
            if (numeric32_direct_attribution) numeric32_coverage.direct_division++;
        case Numeric32Fault.SHIFT:
            numeric32_coverage.shifts++;
            if (numeric32_direct_attribution) numeric32_coverage.direct_shifts++;
        case Numeric32Fault.BOUNDS:
            numeric32_coverage.bounds++;
            if (numeric32_direct_attribution) numeric32_coverage.direct_bounds++;
        case Numeric32Fault.DEAD:
            numeric32_coverage.dead++;
            if (numeric32_direct_attribution) numeric32_coverage.direct_dead++;
        default: unreachable();
    }
}

fn bool numeric32_legal(Numeric32Op op, Numeric32Type type) {
    if (op == Numeric32Op.SLT || op == Numeric32Op.SHR) return type == Numeric32Type.I32;
    if (op == Numeric32Op.ULT) return type == Numeric32Type.U32;
    return true;
}

fn int numeric32_required_faults(Numeric32Op op, Numeric32Type type) {
    if (!numeric32_legal(op, type)) return 0;
    switch (op) {
        case Numeric32Op.CADD: case Numeric32Op.CSUB: case Numeric32Op.CMUL:
        case Numeric32Op.DIV: case Numeric32Op.MOD:
            return type == Numeric32Type.I32 ? 2 : 1;
        case Numeric32Op.CINC: case Numeric32Op.CDEC:
            return 1;
        case Numeric32Op.SHL: case Numeric32Op.SHR: case Numeric32Op.USHR:
        case Numeric32Op.LOAD: case Numeric32Op.STORE:
            return 2;
        default:
            return 0;
    }
}

fn bool numeric32_form_coverage_ok(Numeric32Op op, Numeric32Type type) {
    if (op == Numeric32Op.MOV_IMM) {
        return numeric32_form_get(op, type, true) > 0;
    }
    if (op == Numeric32Op.MOV_REG || op == Numeric32Op.INC ||
            op == Numeric32Op.DEC || op == Numeric32Op.CINC ||
            op == Numeric32Op.CDEC) {
        return numeric32_dirty_get(op, type, false) > 0;
    }
    return numeric32_form_get(op, type, true) > 0 &&
        numeric32_form_get(op, type, false) > 0 &&
        numeric32_dirty_get(op, type, true) > 0 &&
        numeric32_dirty_get(op, type, false) > 0;
}

fn ulong numeric32_direct_fault_get(Numeric32Op op, Numeric32Type type) {
    return type == Numeric32Type.I32
        ? numeric32_coverage.direct_fault_i32[(int)op]
        : numeric32_coverage.direct_fault_u32[(int)op];
}

fn bool numeric32_direct_totals_ok() {
    bool exact = numeric32_coverage.direct_faults == 37 &&
        numeric32_coverage.direct_checked == 13 && numeric32_coverage.direct_division == 6 &&
        numeric32_coverage.direct_shifts == 10 && numeric32_coverage.direct_bounds == 4 &&
        numeric32_coverage.direct_dead == 4 && numeric32_coverage.shift33_immediate > 0 &&
        numeric32_coverage.shift33_register > 0;
    return expect(exact, "numeric32 deterministic failure attribution must be exact");
}

fn bool numeric32_coverage_ok() {
    if (!expect(numeric32_coverage.valid == 64 && numeric32_coverage.faults == 64,
            "numeric32 oracle needs exactly 64 valid and 64 fault programs")) return false;
    if (!numeric32_direct_totals_ok()) return false;
    for (int op = 0; op < NUMERIC32_OP_COUNT; op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric32Type type = (Numeric32Type)raw_type;
            if (!numeric32_legal((Numeric32Op)op, type)) continue;
            if (!expect(numeric32_success_get((Numeric32Op)op, type) > 0,
                    "numeric32 every legal op/type needs success coverage")) return false;
            int required = numeric32_required_faults((Numeric32Op)op, type);
            if (!expect((int)numeric32_fault_get((Numeric32Op)op, type) >= required,
                    "numeric32 per-op/type fault coverage")) return false;
            if (!expect((int)numeric32_direct_fault_get((Numeric32Op)op, type) == required,
                    "numeric32 deterministic failing_ops must match exactly")) return false;
            if (!expect(numeric32_form_coverage_ok((Numeric32Op)op, type),
                    "numeric32 operand forms and dirty inputs need explicit coverage")) {
                return false;
            }
        }
    }
    return true;
}

fn void numeric32_coverage_print() {
    io::printfn("NUMERIC32_COVERAGE valid=%d fault=%d checked=%d division=%d",
        numeric32_coverage.valid, numeric32_coverage.faults,
        numeric32_coverage.checked, numeric32_coverage.division);
    io::printfn("NUMERIC32_FAULTS shifts=%d bounds=%d dead=%d",
        numeric32_coverage.shifts, numeric32_coverage.bounds, numeric32_coverage.dead);
    io::printfn("NUMERIC32_DIRECT checked=%d division=%d shifts=%d memory=%d",
        numeric32_coverage.direct_checked, numeric32_coverage.direct_division,
        numeric32_coverage.direct_shifts,
        numeric32_coverage.direct_bounds + numeric32_coverage.direct_dead);
}
