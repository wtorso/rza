module rza_tests;

const int NUMERIC32_OP_COUNT = 24;

enum Numeric32Type : char {
    I32,
    U32,
}

enum Numeric32Op : char {
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

enum Numeric32Fault : char {
    NONE,
    ARITHMETIC,
    DIVISION,
    SHIFT,
    BOUNDS,
    DEAD,
}

fn int numeric32_reference_selftest() {
    Numeric32Fault failure = Numeric32Fault.NONE;
    long wrapped = numeric32_evaluate(Numeric32Op.ADD, Numeric32Type.I32,
        2147483647, 1, &failure);
    if (wrapped != -2147483648 || failure != Numeric32Fault.NONE) return 1;
    long checked = numeric32_evaluate(Numeric32Op.CADD, Numeric32Type.I32,
        2147483647, 1, &failure);
    if (checked != 0 || failure != Numeric32Fault.ARITHMETIC) return 1;
    failure = Numeric32Fault.NONE;
    checked = numeric32_evaluate(Numeric32Op.CMUL, Numeric32Type.U32,
        4294967295, 4294967295, &failure);
    if (checked != 0 || failure != Numeric32Fault.ARITHMETIC) return 1;
    failure = Numeric32Fault.NONE;
    long divided = numeric32_evaluate(Numeric32Op.DIV, Numeric32Type.I32,
        -2147483648, -1, &failure);
    if (divided != 0 || failure != Numeric32Fault.DIVISION) return 1;
    failure = Numeric32Fault.NONE;
    long shifted = numeric32_evaluate(Numeric32Op.SHR, Numeric32Type.I32,
        -2147483648, 31, &failure);
    if (shifted != -1) return 1;
    shifted = numeric32_evaluate(Numeric32Op.USHR, Numeric32Type.I32,
        -2147483648, 31, &failure);
    if (shifted != 1) return 1;
    if (numeric32_evaluate(Numeric32Op.ULT, Numeric32Type.U32, 0, 4294967295, &failure) != 1) {
        return 1;
    }
    return failure == Numeric32Fault.NONE ? 0 : 1;
}

fn long numeric32_normalize(Numeric32Type type, ulong bits) {
    long low = (long)(bits & 0xffffffff);
    if (type == Numeric32Type.I32 && low >= 2147483648) return low - 4294967296;
    return low;
}

fn long numeric32_wrap_value(Numeric32Type type, int128 value) {
    int128 remainder = value % 4294967296;
    if (remainder < 0) remainder += 4294967296;
    return numeric32_normalize(type, (ulong)remainder);
}

fn long numeric32_checked(Numeric32Op op, Numeric32Type type, long left, long right,
        Numeric32Fault* failure) {
    int128 value;
    switch (op) {
        case Numeric32Op.CADD: case Numeric32Op.CINC:
            value = (int128)left + (int128)right;
        case Numeric32Op.CSUB: case Numeric32Op.CDEC:
            value = (int128)left - (int128)right;
        case Numeric32Op.CMUL:
            value = (int128)left * (int128)right;
        default: unreachable();
    }
    bool invalid = type == Numeric32Type.I32
        ? value < -2147483648 || value > 2147483647
        : value < 0 || value > 4294967295;
    if (invalid) {
        *failure = Numeric32Fault.ARITHMETIC;
        return 0;
    }
    return numeric32_wrap_value(type, value);
}

fn long numeric32_divide(Numeric32Op op, Numeric32Type type, long left, long right,
        Numeric32Fault* failure) {
    if (right == 0 || type == Numeric32Type.I32 && left == -2147483648 && right == -1) {
        *failure = Numeric32Fault.DIVISION;
        return 0;
    }
    int128 value = op == Numeric32Op.DIV
        ? (int128)left / (int128)right
        : (int128)left % (int128)right;
    return numeric32_wrap_value(type, value);
}

fn long numeric32_shift(Numeric32Op op, Numeric32Type type, long left, long count,
        Numeric32Fault* failure) {
    if (count < 0 || count >= 32) {
        *failure = Numeric32Fault.SHIFT;
        return 0;
    }
    ulong bits = (ulong)left & 0xffffffff;
    uint amount = (uint)count;
    if (op == Numeric32Op.SHL) bits <<= amount;
    if (op == Numeric32Op.USHR) bits >>= amount;
    if (op == Numeric32Op.SHR) {
        if (amount > 0 && (bits & 0x80000000) != 0) bits |= ~0xffffffffUL;
        bits >>= amount;
    }
    return numeric32_normalize(type, bits);
}


fn long numeric32_evaluate(Numeric32Op op, Numeric32Type type, long left, long right,
        Numeric32Fault* failure) {
    *failure = Numeric32Fault.NONE;
    long signed_left = numeric32_normalize(type, (ulong)left);
    long signed_right = numeric32_normalize(type, (ulong)right);
    if (op == Numeric32Op.CADD || op == Numeric32Op.CSUB || op == Numeric32Op.CMUL) {
        return numeric32_checked(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric32Op.CINC || op == Numeric32Op.CDEC) {
        return numeric32_checked(op, type, signed_left, 1, failure);
    }
    if (op == Numeric32Op.DIV || op == Numeric32Op.MOD) {
        return numeric32_divide(op, type, signed_left, signed_right, failure);
    }
    if (op == Numeric32Op.SHL || op == Numeric32Op.SHR || op == Numeric32Op.USHR) {
        return numeric32_shift(op, type, left, right, failure);
    }
    if (op == Numeric32Op.INC) return numeric32_wrap_value(type, (int128)signed_left + 1);
    if (op == Numeric32Op.DEC) return numeric32_wrap_value(type, (int128)signed_left - 1);
    if (op == Numeric32Op.SLT || op == Numeric32Op.ULT) return signed_left < signed_right ? 1 : 0;
    if (op == Numeric32Op.ADD || op == Numeric32Op.SUB || op == Numeric32Op.MUL) {
        int128 value = op == Numeric32Op.ADD ? (int128)signed_left + signed_right
            : op == Numeric32Op.SUB ? (int128)signed_left - signed_right
            : (int128)signed_left * signed_right;
        return numeric32_wrap_value(type, value);
    }
    ulong left_bits = (ulong)left & 0xffffffff;
    ulong right_bits = (ulong)right & 0xffffffff;
    ulong bits = op == Numeric32Op.AND ? left_bits & right_bits
        : op == Numeric32Op.OR ? left_bits | right_bits
        : left_bits ^ right_bits;
    return numeric32_normalize(type, bits);
}
