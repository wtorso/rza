module rza_tests;

import std::core::dstring;
import std::io;

const int FLOAT_OWNED_FORMS = 34;
const int FLOAT_GLOBAL_FORMS = 240;
const ulong FLOAT_VALUE_FINITE = 1;
const ulong FLOAT_VALUE_ZERO = 2;
const ulong FLOAT_VALUE_INFINITY = 4;
const ulong FLOAT_VALUE_NAN = 8;
const ulong FLOAT_CONTEXT_RAW = 1;
const ulong FLOAT_CONTEXT_LAYOUT = 2;
const ulong FLOAT_CONTEXT_PROC = 4;
const ulong FLOAT_CONTEXT_SYNC = 8;
const ulong FLOAT_CONTEXT_ASYNC = 16;
const ulong FLOAT_CONTEXT_DIRTY = 32;
const ulong FLOAT_FAULT_BOUNDS = 1;
const ulong FLOAT_FAULT_DEAD = 2;
const ulong FLOAT_FAULT_CONVERSIONS = 0x7f;

struct FloatCoverage {
    ulong[FLOAT_OWNED_FORMS] valid_scenarios;
    ulong[FLOAT_OWNED_FORMS] fault_scenarios;
    ulong[FLOAT_OWNED_FORMS] value_classes;
    ulong[FLOAT_OWNED_FORMS] operand_forms;
    ulong[FLOAT_OWNED_FORMS] contexts;
    ulong[FLOAT_OWNED_FORMS] rounding_ties;
    ulong direct_invalid_destinations;
    ulong valid;
    ulong faults;
    ulong direct_invalid;
    ulong direct_memory;
    ulong other_faults;
    ulong dirty;
}

FloatCoverage float_coverage;
bool float_direct_attribution;

fn String float_width_name(FloatWidth width) {
    return width == FloatWidth.F32 ? "f32" : "f64";
}

fn String float_base_name(int index) {
    String[] names = {
        "mov", "load", "store", "add", "sub", "mul", "div", "feq", "fne",
        "flt", "fle", "fgt", "fge",
    };
    assert(index >= 0 && index < 13);
    return names[index];
}

fn FloatInteger float_integer_at(int index) {
    assert(index >= 0 && index < 8);
    return (FloatInteger)index;
}

fn String float_owned_name(FloatWidth width, int index) {
    String fp = float_width_name(width);
    if (index < 13) return string::tformat("%s.%s", float_base_name(index), fp);
    if (index < 29) {
        int integer = (index - 13) / 2;
        String name = float_integer_name(float_integer_at(integer));
        if ((index - 13) % 2 == 0) return string::tformat("cvt.%s.%s", fp, name);
        return string::tformat("cvt.%s.%s", name, fp);
    }
    if (index == 29) {
        return width == FloatWidth.F32 ? "cvt.f64.f32" : "cvt.f32.f64";
    }
    FloatInteger signed = width == FloatWidth.F32 ? FloatInteger.I32 : FloatInteger.I64;
    FloatInteger unsigned = width == FloatWidth.F32 ? FloatInteger.U32 : FloatInteger.U64;
    bool signed_pair = index == 30 || index == 32;
    String integer = float_integer_name(signed_pair ? signed : unsigned);
    if (index < 32) return string::tformat("bitcast.%s.%s", fp, integer);
    return string::tformat("bitcast.%s.%s", integer, fp);
}

fn ulong float_value_class(FloatValue value) {
    switch (value.class) {
        case FloatClass.ZERO: return FLOAT_VALUE_ZERO;
        case FloatClass.FINITE: return FLOAT_VALUE_FINITE;
        case FloatClass.INFINITY: return FLOAT_VALUE_INFINITY;
        case FloatClass.NAN: return FLOAT_VALUE_NAN;
    }
    unreachable();
}

fn ulong float_result_class(FloatResult result) {
    switch (result.class) {
        case FloatClass.ZERO: return FLOAT_VALUE_ZERO;
        case FloatClass.FINITE: return FLOAT_VALUE_FINITE;
        case FloatClass.INFINITY: return FLOAT_VALUE_INFINITY;
        case FloatClass.NAN: return FLOAT_VALUE_NAN;
    }
    unreachable();
}

fn ulong float_case_context(FloatCase item) {
    ulong mask = item.context == 0 || item.context == 5
        ? FLOAT_CONTEXT_RAW : (ulong)1 << item.context;
    if (item.dirty) mask |= FLOAT_CONTEXT_DIRTY;
    return mask;
}

fn void float_cover_valid(FloatCase item) {
    int index = item.form;
    assert(index >= 0 && index < FLOAT_OWNED_FORMS);
    float_coverage.valid_scenarios[index] |= (ulong)1 << item.scenario;
    float_coverage.contexts[index] |= float_case_context(item);
    float_coverage.valid++;
    if (index >= 3 && index < 13) {
        float_coverage.operand_forms[index] |= item.immediate ? 1 : 2;
        float_coverage.value_classes[index] |=
            float_value_class(float_decode(item.left, item.width)) |
            float_value_class(float_decode(item.right, item.width));
        if (index <= 6) {
            float_coverage.value_classes[index] |= float_result_class(float_case_result(item));
        }
        return;
    }
    if (index >= 13 && index < 29) {
        float_coverage.value_classes[index] |= FLOAT_VALUE_FINITE;
        if (item.rounding_tie) float_coverage.rounding_ties[index] = 1;
        return;
    }
    if (index == 29) {
        float_coverage.value_classes[index] |=
            float_value_class(float_decode(item.left, item.width)) |
            float_result_class(float_case_result(item));
    }
}

fn void float_cover_dirty() {
    float_coverage.dirty++;
}

fn void float_cover_fault(FloatCase item) {
    int index = item.form;
    assert(index >= 0 && index < FLOAT_OWNED_FORMS);
    float_coverage.fault_scenarios[index] |= (ulong)1 << item.fault_scenario;
    float_coverage.faults++;
    if (!float_direct_attribution) {
        float_coverage.other_faults++;
        return;
    }
    if (item.failure == 1) {
        float_coverage.direct_invalid++;
        int destination = (index - 14) / 2;
        assert(destination >= 0 && destination < 8);
        float_coverage.direct_invalid_destinations |= (ulong)1 << destination;
    } else {
        float_coverage.direct_memory++;
    }
}

fn bool float_integer_signed_name(String type) {
    return type == "i8" || type == "i16" || type == "i32" || type == "i64";
}

fn int float_integer_global_names(String[] output) {
    String[] types = { "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64" };
    String[] operations = {
        "mov", "load", "store", "add", "sub", "mul", "inc", "dec", "cadd", "csub",
        "cmul", "cinc", "cdec", "and", "or", "xor", "div", "mod", "shl", "ushr",
    };
    int count = 0;
    foreach (type : types) {
        foreach (operation : operations) {
            output[count++] = string::tformat("%s.%s", operation, type);
        }
        String comparison = float_integer_signed_name(type) ? "slt" : "ult";
        output[count++] = string::tformat("%s.%s", comparison, type);
        if (float_integer_signed_name(type)) {
            output[count++] = string::tformat("shr.%s", type);
        }
    }
    assert(count == 172);
    return count;
}

fn bool float_global_matrix_ok() {
    String[FLOAT_GLOBAL_FORMS] names;
    int count = float_integer_global_names(names[..]);
    for (int width = 0; width < 2; width++) {
        for (int i = 0; i < FLOAT_OWNED_FORMS; i++) {
            names[count++] = float_owned_name((FloatWidth)width, i);
        }
    }
    if (!expect(count == FLOAT_GLOBAL_FORMS, "global matrix must contain 240 forms")) {
        return false;
    }
    for (int i = 0; i < count; i++) {
        for (int j = i + 1; j < count; j++) {
            if (!expect(names[i] != names[j], "global matrix duplicate or gap")) return false;
        }
    }
    return true;
}

fn ulong float_required_context(int index) {
    ulong mask = FLOAT_CONTEXT_RAW;
    if (index < 30) {
        switch (index % 6) {
            case 1: mask |= FLOAT_CONTEXT_LAYOUT; break;
            case 2: mask |= FLOAT_CONTEXT_PROC; break;
            case 3: mask |= FLOAT_CONTEXT_SYNC; break;
            case 4: mask |= FLOAT_CONTEXT_ASYNC; break;
            default: break;
        }
    }
    if (index == 0) mask |= FLOAT_CONTEXT_DIRTY;
    return mask;
}

fn ulong float_required_values(int index) {
    if (index == 3 || index == 4) {
        return FLOAT_VALUE_FINITE | FLOAT_VALUE_INFINITY | FLOAT_VALUE_NAN;
    }
    if (index == 5) {
        return FLOAT_VALUE_FINITE | FLOAT_VALUE_ZERO |
            FLOAT_VALUE_INFINITY | FLOAT_VALUE_NAN;
    }
    if (index == 6) return FLOAT_VALUE_FINITE | FLOAT_VALUE_ZERO | FLOAT_VALUE_NAN;
    if (index >= 7 && index < 13) return FLOAT_VALUE_FINITE | FLOAT_VALUE_NAN;
    if (index >= 13 && index < 29) return FLOAT_VALUE_FINITE;
    if (index == 29) return FLOAT_VALUE_FINITE | FLOAT_VALUE_NAN;
    return 0;
}

fn ulong float_required_ties(FloatWidth width, int index) {
    if (index != 21 && index != 23 && index != 25 && index != 27) return 0;
    if (width == FloatWidth.F32) return 1;
    return index >= 25 ? 1 : 0;
}

fn ulong float_required_faults(int index) {
    if (index == 1 || index == 2) return FLOAT_FAULT_BOUNDS | FLOAT_FAULT_DEAD;
    if (index >= 14 && index < 29 && index % 2 == 0) return FLOAT_FAULT_CONVERSIONS;
    return 0;
}

fn bool float_coverage_masks_ok(FloatWidth width) {
    if (float_coverage.direct_invalid_destinations != 0xff) return false;
    for (int i = 0; i < FLOAT_OWNED_FORMS; i++) {
        ulong scenarios = i < 30 ? 3 : 1;
        ulong operands = i >= 3 && i < 13 ? 3 : 0;
        if (float_coverage.valid_scenarios[i] != scenarios) return false;
        if (float_coverage.fault_scenarios[i] != float_required_faults(i)) return false;
        if (float_coverage.value_classes[i] != float_required_values(i)) return false;
        if (float_coverage.operand_forms[i] != operands) return false;
        if (float_coverage.contexts[i] != float_required_context(i)) return false;
        if (float_coverage.rounding_ties[i] != float_required_ties(width, i)) return false;
    }
    return true;
}

fn bool float_coverage_controls_ok(FloatWidth width) {
    FloatCoverage saved = float_coverage;
    float_coverage.valid_scenarios[0] &= ~(ulong)1;
    bool valid_rejected = !float_coverage_masks_ok(width);
    float_coverage = saved;
    float_coverage.fault_scenarios[14] &= ~(ulong)1;
    bool fault_rejected = !float_coverage_masks_ok(width);
    float_coverage = saved;
    float_coverage.direct_invalid_destinations &= ~(ulong)1;
    bool destination_rejected = !float_coverage_masks_ok(width);
    float_coverage = saved;
    return expect(valid_rejected && fault_rejected && destination_rejected,
        "coverage negative controls");
}

fn void float_coverage_reset() {
    float_coverage = {};
    float_direct_attribution = false;
}

fn bool float_coverage_ok(FloatWidth width) {
    if (!expect(float_coverage.valid == 64 && float_coverage.faults == 64,
            "float oracle needs exactly 64 valid and 64 fault programs")) return false;
    if (!expect(float_coverage.direct_invalid == 8 && float_coverage.direct_memory == 8 &&
            float_coverage.other_faults == 48,
            "float direct and remaining fault attribution")) return false;
    if (!expect(float_coverage.dirty > 0, "dirty f32 coverage")) return false;
    if (!expect(float_coverage_masks_ok(width), "exact per-form coverage masks")) return false;
    return float_global_matrix_ok() && float_coverage_controls_ok(width);
}
