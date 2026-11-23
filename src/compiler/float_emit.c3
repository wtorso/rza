module rez3asm;

fn bool scalar_type_is_float(ScalarType type) {
    return type == ScalarType.F32 || type == ScalarType.F64;
}

fn bool program_has_float() {
    foreach (ins : instrs) {
        if (scalar_type_is_float(ins.scalar_type)) return true;
        if (scalar_type_is_float(ins.source_type)) return true;
    }
    return false;
}

fn void emit_float_pragmas(Output* out) {
    out.append_string("#if defined(__clang__)\n");
    out.append_string("#pragma clang fp reassociate(off)\n");
    out.append_string("#pragma STDC FP_CONTRACT OFF\n");
    out.append_string("#elif defined(__GNUC__)\n");
    out.append_string("#pragma GCC optimize (\"fp-contract=off\")\n#endif\n");
    out.append_string("#if defined(_MSC_VER)\n");
    out.append_string("#pragma float_control(precise, on)\n");
    out.append_string("#pragma float_control(except, off)\n");
    out.append_string("#pragma fenv_access(off)\n#pragma fp_contract(off)\n#endif\n\n");
}

fn void emit_float_profile_guards(Output* out) {
    out.append_string("#if (defined(__FAST_MATH__) && __FAST_MATH__ != 0) || \\\n");
    out.append_string("    (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__ != 0)\n");
    out.append_string("#error \"fast-math or finite-only mode is enabled\"\n#endif\n");
    out.append_string("_Static_assert(CHAR_BIT == 8, \"eight-bit bytes required\");\n");
    out.append_string("_Static_assert(sizeof(float) == 4, \"binary32 size required\");\n");
    out.append_string("_Static_assert(sizeof(double) == 8, \"binary64 size required\");\n");
    out.append_string("_Static_assert(FLT_RADIX == 2, \"binary radix required\");\n");
    out.append_string("_Static_assert(FLT_MANT_DIG == 24, \"binary32 mantissa required\");\n");
    out.append_string("_Static_assert(DBL_MANT_DIG == 53, \"binary64 mantissa required\");\n");
    out.append_string("_Static_assert(FLT_MIN_EXP == -125, \"binary32 minimum exponent\");\n");
    out.append_string("_Static_assert(FLT_MAX_EXP == 128, \"binary32 maximum exponent\");\n");
    out.append_string("_Static_assert(DBL_MIN_EXP == -1021, \"binary64 minimum exponent\");\n");
    out.append_string("_Static_assert(DBL_MAX_EXP == 1024, \"binary64 maximum exponent\");\n");
    out.append_string("#if FLT_EVAL_METHOD != 0\n");
    out.append_string("#error \"floating evaluation must round at the declared type\"\n#endif\n");
    out.append_string("#if defined(__STDC_IEC_559__) && __STDC_IEC_559__ != 1\n");
    out.append_string("#error \"inconsistent IEC 60559 declaration\"\n#endif\n\n");
}

fn void emit_float_support(Output* out) {
    if (!program_has_float()) return;
    out.append_string("#include <float.h>\n#include <limits.h>\n\n");
    emit_float_pragmas(out);
    emit_float_profile_guards(out);
}

fn void emit_float_load(
    Output* out,
    int ind,
    Instr* ins,
    String ptr,
    String offset
) {
    bool single = ins.scalar_type == ScalarType.F32;
    assert(single || ins.scalar_type == ScalarType.F64);
    out.appendf("{ uint%d_t value;\n", single ? 32 : 64);
    pad(out, ind + 1);
    out.appendf("memcpy(&value, (char*)%s + %s, %d);\n", ptr, offset, single ? 4 : 8);
    pad(out, ind + 1);
    out.appendf("r%d = %s(value); }\n", ins.a, single ? "rez_f32_from_bits"
        : "rez_f64_from_bits");
}

fn void emit_float_store(
    Output* out,
    int ind,
    Instr* ins,
    String ptr,
    String offset
) {
    bool single = ins.scalar_type == ScalarType.F32;
    assert(single || ins.scalar_type == ScalarType.F64);
    out.appendf("{ uint%d_t value = (uint%d_t)rez_i64_bits(r%d);\n",
        single ? 32 : 64, single ? 32 : 64, ins.a);
    pad(out, ind + 1);
    out.appendf("memcpy((char*)%s + %s, &value, %d);\n", ptr, offset, single ? 4 : 8);
    pad(out, ind);
    out.append_string("}\n");
}

fn void emit_float_mov(Output* out, int ind, Instr* ins) {
    bool immediate = ins.operand_kind == OperandKind.IMMEDIATE;
    bool single = ins.scalar_type == ScalarType.F32;
    assert(single || ins.scalar_type == ScalarType.F64);
    pad(out, ind);
    String helper = single ? "rez_f32_from_bits" : "rez_f64_from_bits";
    if (!immediate) {
        out.appendf("r%d = %s((uint64_t)r%d);\n", ins.a, helper, ins.b);
        return;
    }
    if (single) {
        out.appendf("r%d = %s(0x%08xULL);\n", ins.a, helper, (uint)ins.immediate.bits);
    } else {
        out.appendf("r%d = %s(0x%016xULL);\n", ins.a, helper, (ulong)ins.immediate.bits);
    }
}


fn String float_alu_helper(AluOp op, bool single) {
    switch (op) {
        case AluOp.ADD: return single ? "rez_f32_add" : "rez_f64_add";
        case AluOp.SUB: return single ? "rez_f32_sub" : "rez_f64_sub";
        case AluOp.MUL: return single ? "rez_f32_mul" : "rez_f64_mul";
        case AluOp.DIV: return single ? "rez_f32_div" : "rez_f64_div";
        case AluOp.FEQ: return single ? "rez_f32_feq" : "rez_f64_feq";
        case AluOp.FNE: return single ? "rez_f32_fne" : "rez_f64_fne";
        case AluOp.FLT: return single ? "rez_f32_flt" : "rez_f64_flt";
        case AluOp.FLE: return single ? "rez_f32_fle" : "rez_f64_fle";
        case AluOp.FGT: return single ? "rez_f32_fgt" : "rez_f64_fgt";
        case AluOp.FGE: return single ? "rez_f32_fge" : "rez_f64_fge";
        default: unreachable("unsupported floating arithmetic operation");
    }
}

fn void emit_float_alu3(Output* out, int ind, Instr* ins) {
    bool single = ins.scalar_type == ScalarType.F32;
    assert(single || ins.scalar_type == ScalarType.F64);
    String helper = float_alu_helper(ins.alu_op, single);
    pad(out, ind);
    if (ins.operand_kind != OperandKind.IMMEDIATE) {
        out.appendf("r%d = %s(r%d, r%d);\n", ins.a, helper, ins.b, ins.c);
        return;
    }
    String bits_helper = single ? "rez_f32_from_bits" : "rez_f64_from_bits";
    if (single) {
        out.appendf("r%d = %s(r%d, %s(0x%08xULL));\n", ins.a, helper, ins.b,
            bits_helper, (uint)ins.immediate.bits);
    } else {
        out.appendf("r%d = %s(r%d, %s(0x%016xULL));\n", ins.a, helper, ins.b,
            bits_helper, (ulong)ins.immediate.bits);
    }
}


fn void emit_float_bitcast(Output* out, int ind, Instr* ins) {
    assert(ins.op == Op.BITCAST);
    assert(scalar_type_desc(ins.scalar_type).bit_width ==
        scalar_type_desc(ins.source_type).bit_width);
    pad(out, ind);
    if (ins.scalar_type == ScalarType.I64) {
        out.appendf("r%d = rez_i64_value(rez_i64_bits(r%d));\n", ins.a, ins.b);
        return;
    }
    String helper = cat({"rez_", scalar_type_desc(ins.scalar_type).source_name, "_from_bits"});
    out.appendf("r%d = %s(rez_i64_bits(r%d));\n", ins.a, helper, ins.b);
}

fn String float_cvt_value_helper(Instr* ins) {
    if (ins.scalar_type == ScalarType.F32 && ins.source_type == ScalarType.F64) {
        return "rez_f32_from_f64";
    }
    if (ins.scalar_type == ScalarType.F64 && ins.source_type == ScalarType.F32) {
        return "rez_f64_from_f32";
    }
    bool single = ins.scalar_type == ScalarType.F32;
    assert(single || ins.scalar_type == ScalarType.F64);
    bool signed = scalar_type_desc(ins.source_type).signedness == Signedness.SIGNED;
    if (single) return signed ? "rez_f32_from_i64" : "rez_f32_from_u64";
    return signed ? "rez_f64_from_i64" : "rez_f64_from_u64";
}

fn String float_cvt_integer_helper(Instr* ins) {
    assert(!scalar_type_is_float(ins.scalar_type));
    assert(scalar_type_is_float(ins.source_type));
    return cat({
        "rez_", ins.source_type == ScalarType.F32 ? "f32" : "f64", "_to_",
        scalar_type_desc(ins.scalar_type).source_name
    });
}

fn void emit_float_cvt(Output* out, int ind, Instr* ins) {
    assert(ins.op == Op.CVT);
    if (!scalar_type_is_float(ins.scalar_type)) {
        String helper = float_cvt_integer_helper(ins);
        pad(out, ind);
        out.appendf("if (%s(r%d, &r%d)) {\n", helper, ins.b, ins.a);
        emit_coded_fault(out, ind + 1, "RZA_FAULT_ARITHMETIC_OVERFLOW", ins.line,
            "invalid conversion", "");
        pad(out, ind);
        out.append_string("}\n");
        return;
    }
    String helper = float_cvt_value_helper(ins);
    pad(out, ind);
    out.appendf("r%d = %s(r%d);\n", ins.a, helper, ins.b);
}

fn void emit_float_conversion(Output* out, int ind, Instr* ins) {
    if (ins.op == Op.BITCAST) {
        emit_float_bitcast(out, ind, ins);
        return;
    }
    emit_float_cvt(out, ind, ins);
}
