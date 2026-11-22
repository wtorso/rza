module rza_tests;

const int NUMERIC8_OP_COUNT = 24;

enum Numeric8Type : char {
    I8,
    U8,
}

enum Numeric8Op : char {
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

enum Numeric8Fault : char {
    NONE,
    ARITHMETIC,
    DIVISION,
    SHIFT,
    BOUNDS,
    DEAD,
}

fn int numeric8_reference_selftest() {
    Numeric8Fault failure = Numeric8Fault.NONE;
    if (numeric8_evaluate(Numeric8Op.ADD, Numeric8Type.I8, 127, 1, &failure) != -128) return 1;
    if (failure != Numeric8Fault.NONE) return 1;
    if (numeric8_evaluate(Numeric8Op.CADD, Numeric8Type.I8, 127, 1, &failure) != 0) return 1;
    if (failure != Numeric8Fault.ARITHMETIC) return 1;
    failure = Numeric8Fault.NONE;
    if (numeric8_evaluate(Numeric8Op.DIV, Numeric8Type.I8, -128, -1, &failure) != 0) return 1;
    if (failure != Numeric8Fault.DIVISION) return 1;
    failure = Numeric8Fault.NONE;
    if (numeric8_evaluate(Numeric8Op.SHR, Numeric8Type.I8, -128, 7, &failure) != -1) return 1;
    if (numeric8_evaluate(Numeric8Op.USHR, Numeric8Type.I8, -128, 7, &failure) != 1) return 1;
    if (numeric8_evaluate(Numeric8Op.ULT, Numeric8Type.U8, 0, 255, &failure) != 1) return 1;
    return failure == Numeric8Fault.NONE ? 0 : 1;
}

fn long numeric8_normalize(Numeric8Type type, ulong bits) {
    int low = (int)(bits & 0xff);
    if (type == Numeric8Type.I8 && low >= 128) return (long)low - 256;
    return (long)low;
}

fn long numeric8_wrap_value(Numeric8Type type, int128 value) {
    int128 remainder = value % 256;
    if (remainder < 0) remainder += 256;
    return numeric8_normalize(type, (ulong)remainder);
}

fn long numeric8_checked(Numeric8Op op, Numeric8Type type, long left, long right,
        Numeric8Fault* failure) {
    int128 value;
    switch (op) {
        case Numeric8Op.CADD: case Numeric8Op.CINC:
            value = (int128)left + (int128)right;
        case Numeric8Op.CSUB: case Numeric8Op.CDEC:
            value = (int128)left - (int128)right;
        case Numeric8Op.CMUL:
            value = (int128)left * (int128)right;
        default: unreachable();
    }
    bool invalid = type == Numeric8Type.I8
        ? value < -128 || value > 127
        : value < 0 || value > 255;
    if (invalid) {
        *failure = Numeric8Fault.ARITHMETIC;
        return 0;
    }
    return numeric8_wrap_value(type, value);
}

fn long numeric8_divide(Numeric8Op op, Numeric8Type type, long left, long right,
        Numeric8Fault* failure) {
    if (right == 0 || type == Numeric8Type.I8 && left == -128 && right == -1) {
        *failure = Numeric8Fault.DIVISION;
        return 0;
    }
    int128 value = op == Numeric8Op.DIV
        ? (int128)left / (int128)right
        : (int128)left % (int128)right;
    return numeric8_wrap_value(type, value);
}

fn long numeric8_shift(Numeric8Op op, Numeric8Type type, long left, long count,
        Numeric8Fault* failure) {
    if (count < 0 || count >= 8) {
        *failure = Numeric8Fault.SHIFT;
        return 0;
    }
    ulong bits = (ulong)left & 0xff;
    uint amount = (uint)count;
    if (op == Numeric8Op.SHL) bits <<= amount;
    if (op == Numeric8Op.USHR) bits >>= amount;
    if (op == Numeric8Op.SHR) {
        if (amount > 0 && (bits & 0x80) != 0) bits |= ~0xffUL;
        bits >>= amount;
    }
    return numeric8_normalize(type, bits);
}

fn long numeric8_evaluate(Numeric8Op op, Numeric8Type type, long left, long right,
        Numeric8Fault* failure) {
    *failure = Numeric8Fault.NONE;
    long signed_left = numeric8_normalize(type, (ulong)left);
    long signed_right = numeric8_normalize(type, (ulong)right);
    if (op == Numeric8Op.CADD || op == Numeric8Op.CSUB || op == Numeric8Op.CMUL) {
        return numeric8_checked(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric8Op.CINC || op == Numeric8Op.CDEC) {
        return numeric8_checked(op, type, signed_left, 1, failure);
    }
    if (op == Numeric8Op.DIV || op == Numeric8Op.MOD) {
        return numeric8_divide(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric8Op.SHL || op == Numeric8Op.SHR || op == Numeric8Op.USHR) {
        return numeric8_shift(op, type, left, right, failure);
    }
    if (op == Numeric8Op.INC) return numeric8_wrap_value(type, (int128)signed_left + 1);
    if (op == Numeric8Op.DEC) return numeric8_wrap_value(type, (int128)signed_left - 1);
    if (op == Numeric8Op.SLT || op == Numeric8Op.ULT) return signed_left < signed_right ? 1 : 0;
    if (op == Numeric8Op.ADD || op == Numeric8Op.SUB || op == Numeric8Op.MUL) {
        int128 value = op == Numeric8Op.ADD ? (int128)signed_left + signed_right
            : op == Numeric8Op.SUB ? (int128)signed_left - signed_right
            : (int128)signed_left * signed_right;
        return numeric8_wrap_value(type, value);
    }
    ulong left_bits = (ulong)left & 0xff;
    ulong right_bits = (ulong)right & 0xff;
    ulong bits = op == Numeric8Op.AND ? left_bits & right_bits
        : op == Numeric8Op.OR ? left_bits | right_bits
        : left_bits ^ right_bits;
    return numeric8_normalize(type, bits);
}
