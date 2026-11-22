module rza_tests;

const int NUMERIC16_OP_COUNT = 24;

enum Numeric16Type : char {
    I16,
    U16,
}

enum Numeric16Op : char {
    MOV_IMM,
    MOV_REG,
    LOAD,
    STORE,
    ADD,
    SUB,
    MUL,
    INC,
    DEC,
    CADD,
    CSUB,
    CMUL,
    CINC,
    CDEC,
    AND,
    OR,
    XOR,
    SLT,
    ULT,
    DIV,
    MOD,
    SHL,
    SHR,
    USHR,
    LEGACY_MOV,
    SETUP_STORE,
    PRINT,
    DECAY,
    RET,
}

enum Numeric16Fault : char {
    NONE,
    ARITHMETIC,
    DIVISION,
    SHIFT,
    BOUNDS,
    DEAD,
}

fn int numeric16_reference_selftest() {
    Numeric16Fault failure = Numeric16Fault.NONE;
    if (numeric16_evaluate(Numeric16Op.ADD, Numeric16Type.I16, 32767, 1, &failure) != -32768) {
        return 1;
    }
    if (failure != Numeric16Fault.NONE) return 1;
    if (numeric16_evaluate(Numeric16Op.CADD, Numeric16Type.I16, 32767, 1, &failure) != 0) {
        return 1;
    }
    if (failure != Numeric16Fault.ARITHMETIC) return 1;
    failure = Numeric16Fault.NONE;
    if (numeric16_evaluate(Numeric16Op.DIV, Numeric16Type.I16, -32768, -1, &failure) != 0) {
        return 1;
    }
    if (failure != Numeric16Fault.DIVISION) return 1;
    failure = Numeric16Fault.NONE;
    if (numeric16_evaluate(Numeric16Op.SHR, Numeric16Type.I16, -32768, 15, &failure) != -1) {
        return 1;
    }
    if (numeric16_evaluate(Numeric16Op.USHR, Numeric16Type.I16, -32768, 15, &failure) != 1) {
        return 1;
    }
    if (numeric16_evaluate(Numeric16Op.ULT, Numeric16Type.U16, 0, 65535, &failure) != 1) {
        return 1;
    }
    return failure == Numeric16Fault.NONE ? 0 : 1;
}

fn long numeric16_normalize(Numeric16Type type, ulong bits) {
    int low = (int)(bits & 0xffff);
    if (type == Numeric16Type.I16 && low >= 32768) return (long)low - 65536;
    return (long)low;
}

fn long numeric16_wrap_value(Numeric16Type type, int128 value) {
    int128 remainder = value % 65536;
    if (remainder < 0) remainder += 65536;
    return numeric16_normalize(type, (ulong)remainder);
}

fn long numeric16_checked(Numeric16Op op, Numeric16Type type, long left, long right,
        Numeric16Fault* failure) {
    int128 value;
    switch (op) {
        case Numeric16Op.CADD: case Numeric16Op.CINC:
            value = (int128)left + (int128)right;
        case Numeric16Op.CSUB: case Numeric16Op.CDEC:
            value = (int128)left - (int128)right;
        case Numeric16Op.CMUL:
            value = (int128)left * (int128)right;
        default: unreachable();
    }
    bool invalid = type == Numeric16Type.I16
        ? value < -32768 || value > 32767
        : value < 0 || value > 65535;
    if (invalid) {
        *failure = Numeric16Fault.ARITHMETIC;
        return 0;
    }
    return numeric16_wrap_value(type, value);
}

fn long numeric16_divide(Numeric16Op op, Numeric16Type type, long left, long right,
        Numeric16Fault* failure) {
    if (right == 0 || type == Numeric16Type.I16 && left == -32768 && right == -1) {
        *failure = Numeric16Fault.DIVISION;
        return 0;
    }
    int128 value = op == Numeric16Op.DIV
        ? (int128)left / (int128)right
        : (int128)left % (int128)right;
    return numeric16_wrap_value(type, value);
}

fn long numeric16_shift(Numeric16Op op, Numeric16Type type, long left, long count,
        Numeric16Fault* failure) {
    if (count < 0 || count >= 16) {
        *failure = Numeric16Fault.SHIFT;
        return 0;
    }
    ulong bits = (ulong)left & 0xffff;
    uint amount = (uint)count;
    if (op == Numeric16Op.SHL) bits <<= amount;
    if (op == Numeric16Op.USHR) bits >>= amount;
    if (op == Numeric16Op.SHR) {
        if (amount > 0 && (bits & 0x8000) != 0) bits |= ~0xffffUL;
        bits >>= amount;
    }
    return numeric16_normalize(type, bits);
}


fn long numeric16_evaluate(Numeric16Op op, Numeric16Type type, long left, long right,
        Numeric16Fault* failure) {
    *failure = Numeric16Fault.NONE;
    long signed_left = numeric16_normalize(type, (ulong)left);
    long signed_right = numeric16_normalize(type, (ulong)right);
    if (op == Numeric16Op.CADD || op == Numeric16Op.CSUB || op == Numeric16Op.CMUL) {
        return numeric16_checked(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric16Op.CINC || op == Numeric16Op.CDEC) {
        return numeric16_checked(op, type, signed_left, 1, failure);
    }
    if (op == Numeric16Op.DIV || op == Numeric16Op.MOD) {
        return numeric16_divide(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric16Op.SHL || op == Numeric16Op.SHR || op == Numeric16Op.USHR) {
        return numeric16_shift(op, type, left, right, failure);
    }
    if (op == Numeric16Op.INC) return numeric16_wrap_value(type, (int128)signed_left + 1);
    if (op == Numeric16Op.DEC) return numeric16_wrap_value(type, (int128)signed_left - 1);
    if (op == Numeric16Op.SLT || op == Numeric16Op.ULT) return signed_left < signed_right ? 1 : 0;
    if (op == Numeric16Op.ADD || op == Numeric16Op.SUB || op == Numeric16Op.MUL) {
        int128 value = op == Numeric16Op.ADD ? (int128)signed_left + signed_right
            : op == Numeric16Op.SUB ? (int128)signed_left - signed_right
            : (int128)signed_left * signed_right;
        return numeric16_wrap_value(type, value);
    }
    ulong left_bits = (ulong)left & 0xffff;
    ulong right_bits = (ulong)right & 0xffff;
    ulong bits = op == Numeric16Op.AND ? left_bits & right_bits
        : op == Numeric16Op.OR ? left_bits | right_bits
        : left_bits ^ right_bits;
    return numeric16_normalize(type, bits);
}
