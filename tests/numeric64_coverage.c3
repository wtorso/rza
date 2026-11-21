module rza_tests;

import std::io;

struct Numeric64Coverage {
    ulong[NUMERIC64_OP_COUNT] success_i64;
    ulong[NUMERIC64_OP_COUNT] success_u64;
    ulong[NUMERIC64_OP_COUNT] fault_i64;
    ulong[NUMERIC64_OP_COUNT] fault_u64;
    ulong[NUMERIC64_OP_COUNT] direct_fault_i64;
    ulong[NUMERIC64_OP_COUNT] direct_fault_u64;
    ulong[NUMERIC64_OP_COUNT] immediate_i64;
    ulong[NUMERIC64_OP_COUNT] immediate_u64;
    ulong[NUMERIC64_OP_COUNT] register_i64;
    ulong[NUMERIC64_OP_COUNT] register_u64;
    ulong[NUMERIC64_OP_COUNT] dirty_immediate_i64;
    ulong[NUMERIC64_OP_COUNT] dirty_immediate_u64;
    ulong[NUMERIC64_OP_COUNT] dirty_register_i64;
    ulong[NUMERIC64_OP_COUNT] dirty_register_u64;
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
    ulong shift65_immediate;
    ulong shift65_register;
}

Numeric64Coverage numeric64_coverage;
bool numeric64_direct_attribution;

fn void numeric64_coverage_reset() {
    numeric64_coverage = {};
    numeric64_direct_attribution = false;
}

fn void numeric64_cover_shift65(bool immediate) {
    if (immediate) {
        numeric64_coverage.shift65_immediate++;
    } else {
        numeric64_coverage.shift65_register++;
    }
}

fn ulong numeric64_success_get(Numeric64Op op, Numeric64Type type) {
    return type == Numeric64Type.I64
        ? numeric64_coverage.success_i64[(int)op]
        : numeric64_coverage.success_u64[(int)op];
}

fn ulong numeric64_fault_get(Numeric64Op op, Numeric64Type type) {
    return type == Numeric64Type.I64
        ? numeric64_coverage.fault_i64[(int)op]
        : numeric64_coverage.fault_u64[(int)op];
}

fn ulong numeric64_form_get(Numeric64Op op, Numeric64Type type, bool immediate) {
    if (type == Numeric64Type.I64) {
        return immediate ? numeric64_coverage.immediate_i64[(int)op]
            : numeric64_coverage.register_i64[(int)op];
    }
    return immediate ? numeric64_coverage.immediate_u64[(int)op]
        : numeric64_coverage.register_u64[(int)op];
}

fn ulong numeric64_dirty_get(Numeric64Op op, Numeric64Type type, bool immediate) {
    if (type == Numeric64Type.I64) {
        return immediate ? numeric64_coverage.dirty_immediate_i64[(int)op]
            : numeric64_coverage.dirty_register_i64[(int)op];
    }
    return immediate ? numeric64_coverage.dirty_immediate_u64[(int)op]
        : numeric64_coverage.dirty_register_u64[(int)op];
}

fn void numeric64_cover_success(Numeric64Op op, Numeric64Type type,
        bool immediate, bool dirty) {
    if (type == Numeric64Type.I64) {
        numeric64_coverage.success_i64[(int)op]++;
        if (immediate) {
            numeric64_coverage.immediate_i64[(int)op]++;
            if (dirty) numeric64_coverage.dirty_immediate_i64[(int)op]++;
        } else {
            numeric64_coverage.register_i64[(int)op]++;
            if (dirty) numeric64_coverage.dirty_register_i64[(int)op]++;
        }
        return;
    }
    numeric64_coverage.success_u64[(int)op]++;
    if (immediate) {
        numeric64_coverage.immediate_u64[(int)op]++;
        if (dirty) numeric64_coverage.dirty_immediate_u64[(int)op]++;
    } else {
        numeric64_coverage.register_u64[(int)op]++;
        if (dirty) numeric64_coverage.dirty_register_u64[(int)op]++;
    }
}

fn void numeric64_cover_fault(Numeric64Op op, Numeric64Type type, Numeric64Fault failure) {
    if (type == Numeric64Type.I64) {
        numeric64_coverage.fault_i64[(int)op]++;
        if (numeric64_direct_attribution) numeric64_coverage.direct_fault_i64[(int)op]++;
    } else {
        numeric64_coverage.fault_u64[(int)op]++;
        if (numeric64_direct_attribution) numeric64_coverage.direct_fault_u64[(int)op]++;
    }
    numeric64_coverage.faults++;
    if (numeric64_direct_attribution) numeric64_coverage.direct_faults++;
    switch (failure) {
        case Numeric64Fault.ARITHMETIC:
            numeric64_coverage.checked++;
            if (numeric64_direct_attribution) numeric64_coverage.direct_checked++;
        case Numeric64Fault.DIVISION:
            numeric64_coverage.division++;
            if (numeric64_direct_attribution) numeric64_coverage.direct_division++;
        case Numeric64Fault.SHIFT:
            numeric64_coverage.shifts++;
            if (numeric64_direct_attribution) numeric64_coverage.direct_shifts++;
        case Numeric64Fault.BOUNDS:
            numeric64_coverage.bounds++;
            if (numeric64_direct_attribution) numeric64_coverage.direct_bounds++;
        case Numeric64Fault.DEAD:
            numeric64_coverage.dead++;
            if (numeric64_direct_attribution) numeric64_coverage.direct_dead++;
        default: unreachable();
    }
}

fn bool numeric64_legal(Numeric64Op op, Numeric64Type type) {
    if (op == Numeric64Op.SLT || op == Numeric64Op.SHR) return type == Numeric64Type.I64;
    if (op == Numeric64Op.ULT) return type == Numeric64Type.U64;
    return true;
}

fn int numeric64_required_faults(Numeric64Op op, Numeric64Type type) {
    if (!numeric64_legal(op, type)) return 0;
    switch (op) {
        case Numeric64Op.CADD: case Numeric64Op.CSUB: case Numeric64Op.CMUL:
        case Numeric64Op.DIV: case Numeric64Op.MOD:
            return type == Numeric64Type.I64 ? 2 : 1;
        case Numeric64Op.CINC: case Numeric64Op.CDEC:
            return 1;
        case Numeric64Op.SHL: case Numeric64Op.SHR: case Numeric64Op.USHR:
        case Numeric64Op.LOAD: case Numeric64Op.STORE:
            return 2;
        default:
            return 0;
    }
}

fn bool numeric64_form_coverage_ok(Numeric64Op op, Numeric64Type type) {
    if (op == Numeric64Op.MOV_IMM) {
        return numeric64_form_get(op, type, true) > 0;
    }
    if (op == Numeric64Op.MOV_REG || op == Numeric64Op.INC ||
            op == Numeric64Op.DEC || op == Numeric64Op.CINC ||
            op == Numeric64Op.CDEC) {
        return numeric64_dirty_get(op, type, false) > 0;
    }
    return numeric64_form_get(op, type, true) > 0 &&
        numeric64_form_get(op, type, false) > 0 &&
        numeric64_dirty_get(op, type, true) > 0 &&
        numeric64_dirty_get(op, type, false) > 0;
}

fn ulong numeric64_direct_fault_get(Numeric64Op op, Numeric64Type type) {
    return type == Numeric64Type.I64
        ? numeric64_coverage.direct_fault_i64[(int)op]
        : numeric64_coverage.direct_fault_u64[(int)op];
}

fn bool numeric64_direct_totals_ok() {
    bool exact = numeric64_coverage.direct_faults == 37 &&
        numeric64_coverage.direct_checked == 13 && numeric64_coverage.direct_division == 6 &&
        numeric64_coverage.direct_shifts == 10 && numeric64_coverage.direct_bounds == 4 &&
        numeric64_coverage.direct_dead == 4 && numeric64_coverage.shift65_immediate > 0 &&
        numeric64_coverage.shift65_register > 0;
    return expect(exact, "numeric64 deterministic failure attribution must be exact");
}

fn bool numeric64_coverage_ok() {
    if (!expect(numeric64_coverage.valid == 64 && numeric64_coverage.faults == 64,
            "numeric64 oracle needs exactly 64 valid and 64 fault programs")) return false;
    if (!numeric64_direct_totals_ok()) return false;
    for (int op = 0; op < NUMERIC64_OP_COUNT; op++) {
        for (int raw_type = 0; raw_type < 2; raw_type++) {
            Numeric64Type type = (Numeric64Type)raw_type;
            if (!numeric64_legal((Numeric64Op)op, type)) continue;
            if (!expect(numeric64_success_get((Numeric64Op)op, type) > 0,
                    "numeric64 every legal op/type needs success coverage")) return false;
            int required = numeric64_required_faults((Numeric64Op)op, type);
            if (!expect((int)numeric64_fault_get((Numeric64Op)op, type) >= required,
                    "numeric64 per-op/type fault coverage")) return false;
            if (!expect((int)numeric64_direct_fault_get((Numeric64Op)op, type) == required,
                    "numeric64 deterministic failing_ops must match exactly")) return false;
            if (!numeric64_form_coverage_ok((Numeric64Op)op, type)) {
                io::eprintfn("numeric64 missing form op=%d type=%d imm=%d reg=%d dimm=%d dreg=%d",
                    op, raw_type, numeric64_form_get((Numeric64Op)op, type, true),
                    numeric64_form_get((Numeric64Op)op, type, false),
                    numeric64_dirty_get((Numeric64Op)op, type, true),
                    numeric64_dirty_get((Numeric64Op)op, type, false));
                return false;
            }
        }
    }
    return true;
}

fn void numeric64_coverage_print() {
    io::printfn("NUMERIC64_COVERAGE valid=%d fault=%d checked=%d division=%d",
        numeric64_coverage.valid, numeric64_coverage.faults,
        numeric64_coverage.checked, numeric64_coverage.division);
    io::printfn("NUMERIC64_FAULTS shifts=%d bounds=%d dead=%d",
        numeric64_coverage.shifts, numeric64_coverage.bounds, numeric64_coverage.dead);
    io::printfn("NUMERIC64_DIRECT checked=%d division=%d shifts=%d memory=%d",
        numeric64_coverage.direct_checked, numeric64_coverage.direct_division,
        numeric64_coverage.direct_shifts,
        numeric64_coverage.direct_bounds + numeric64_coverage.direct_dead);
}
