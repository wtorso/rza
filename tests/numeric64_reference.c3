module rza_tests;

const int NUMERIC64_OP_COUNT = 24;

enum Numeric64Type : char {
    I64,
    U64,
}

enum Numeric64Op : char {
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

enum Numeric64Fault : char {
    NONE,
    ARITHMETIC,
    DIVISION,
    SHIFT,
    BOUNDS,
    DEAD,
}

fn long numeric64_normalize(Numeric64Type type, ulong bits) {
    (void)type;
    if (bits <= (ulong)long::max) return (long)bits;
    return -1 - (long)(ulong::max - bits);
}

fn long numeric64_wrap_signed(Numeric64Type type, int128 value) {
    int128 remainder = value % 18446744073709551616;
    if (remainder < 0) remainder += 18446744073709551616;
    return numeric64_normalize(type, (ulong)remainder);
}

fn long numeric64_wrap_unsigned(uint128 value) {
    return numeric64_normalize(Numeric64Type.U64, (ulong)(value & 0xffffffffffffffff));
}

fn long numeric64_checked_signed(Numeric64Op op, long left, long right,
        Numeric64Fault* failure) {
    int128 value;
    switch (op) {
        case Numeric64Op.CADD: case Numeric64Op.CINC:
            value = (int128)left + (int128)right;
        case Numeric64Op.CSUB: case Numeric64Op.CDEC:
            value = (int128)left - (int128)right;
        case Numeric64Op.CMUL:
            value = (int128)left * (int128)right;
        default: unreachable();
    }
    if (value < -9223372036854775808 || value > 9223372036854775807) {
        *failure = Numeric64Fault.ARITHMETIC;
        return 0;
    }
    return numeric64_wrap_signed(Numeric64Type.I64, value);
}

fn long numeric64_checked_unsigned(Numeric64Op op, ulong left, ulong right,
        Numeric64Fault* failure) {
    if (op == Numeric64Op.CSUB || op == Numeric64Op.CDEC) {
        if (left < right) {
            *failure = Numeric64Fault.ARITHMETIC;
            return 0;
        }
    }
    uint128 value;
    switch (op) {
        case Numeric64Op.CADD: case Numeric64Op.CINC:
            value = (uint128)left + (uint128)right;
        case Numeric64Op.CSUB: case Numeric64Op.CDEC:
            value = (uint128)left - (uint128)right;
        case Numeric64Op.CMUL:
            value = (uint128)left * (uint128)right;
        default: unreachable();
    }
    if (value > 0xffffffffffffffff) {
        *failure = Numeric64Fault.ARITHMETIC;
        return 0;
    }
    return numeric64_wrap_unsigned(value);
}

fn long numeric64_divide_signed(Numeric64Op op, long left, long right,
        Numeric64Fault* failure) {
    if (right == 0 || left == -9223372036854775808 && right == -1) {
        *failure = Numeric64Fault.DIVISION;
        return 0;
    }
    int128 value = op == Numeric64Op.DIV
        ? (int128)left / (int128)right
        : (int128)left % (int128)right;
    return numeric64_wrap_signed(Numeric64Type.I64, value);
}

fn long numeric64_divide_unsigned(Numeric64Op op, ulong left, ulong right,
        Numeric64Fault* failure) {
    if (right == 0) {
        *failure = Numeric64Fault.DIVISION;
        return 0;
    }
    uint128 value = op == Numeric64Op.DIV
        ? (uint128)left / (uint128)right
        : (uint128)left % (uint128)right;
    return numeric64_wrap_unsigned(value);
}

fn long numeric64_shift(Numeric64Op op, Numeric64Type type, long left, long count,
        Numeric64Fault* failure) {
    if (count < 0 || count >= 64) {
        *failure = Numeric64Fault.SHIFT;
        return 0;
    }
    ulong bits = (ulong)left;
    uint amount = (uint)count;
    if (op == Numeric64Op.SHL) bits <<= amount;
    if (op == Numeric64Op.USHR) bits >>= amount;
    if (op == Numeric64Op.SHR && amount > 0) {
        ulong shifted = bits >> amount;
        if ((bits & 0x8000000000000000) != 0) shifted |= ~0UL << (64 - amount);
        bits = shifted;
    }
    return numeric64_normalize(type, bits);
}

fn long numeric64_evaluate(Numeric64Op op, Numeric64Type type, long left, long right,
        Numeric64Fault* failure) {
    *failure = Numeric64Fault.NONE;
    if (op == Numeric64Op.CADD || op == Numeric64Op.CSUB || op == Numeric64Op.CMUL) {
        if (type == Numeric64Type.I64) {
            return numeric64_checked_signed(op, left, right, failure);
        }
        return numeric64_checked_unsigned(op, (ulong)left, (ulong)right, failure);
    }
    if (op == Numeric64Op.CINC || op == Numeric64Op.CDEC) {
        if (type == Numeric64Type.I64) {
            return numeric64_checked_signed(op, left, 1, failure);
        }
        return numeric64_checked_unsigned(op, (ulong)left, 1, failure);
    }
    if (op == Numeric64Op.DIV || op == Numeric64Op.MOD) {
        if (type == Numeric64Type.I64) return numeric64_divide_signed(op, left, right, failure);
        return numeric64_divide_unsigned(op, (ulong)left, (ulong)right, failure);
    }
    if (op == Numeric64Op.SHL || op == Numeric64Op.SHR || op == Numeric64Op.USHR) {
        return numeric64_shift(op, type, left, right, failure);
    }
    if (op == Numeric64Op.INC || op == Numeric64Op.DEC) {
        int delta = op == Numeric64Op.INC ? 1 : -1;
        if (type == Numeric64Type.I64) {
            return numeric64_wrap_signed(type, (int128)left + delta);
        }
        return numeric64_wrap_unsigned((uint128)(ulong)left + (uint128)delta);
    }
    if (op == Numeric64Op.SLT) return left < right ? 1 : 0;
    if (op == Numeric64Op.ULT) return (ulong)left < (ulong)right ? 1 : 0;
    if (op == Numeric64Op.ADD || op == Numeric64Op.SUB || op == Numeric64Op.MUL) {
        if (type == Numeric64Type.I64) {
            int128 value = op == Numeric64Op.ADD ? (int128)left + right
                : op == Numeric64Op.SUB ? (int128)left - right
                : (int128)left * right;
            return numeric64_wrap_signed(type, value);
        }
        uint128 value = op == Numeric64Op.ADD ? (uint128)(ulong)left + (ulong)right
            : op == Numeric64Op.SUB ? (uint128)(ulong)left - (ulong)right
            : (uint128)(ulong)left * (ulong)right;
        return numeric64_wrap_unsigned(value);
    }
    ulong left_bits = (ulong)left;
    ulong right_bits = (ulong)right;
    ulong bits = op == Numeric64Op.AND ? left_bits & right_bits
        : op == Numeric64Op.OR ? left_bits | right_bits
        : left_bits ^ right_bits;
    return numeric64_normalize(type, bits);
}

fn int numeric64_reference_selftest() {
    Numeric64Fault failure = Numeric64Fault.NONE;
    long wrapped = numeric64_evaluate(Numeric64Op.ADD, Numeric64Type.I64,
        9223372036854775807, 1, &failure);
    if (wrapped != -9223372036854775808 || failure != Numeric64Fault.NONE) return 1;
    wrapped = numeric64_evaluate(Numeric64Op.ADD, Numeric64Type.U64, -1, 1, &failure);
    if (wrapped != 0 || failure != Numeric64Fault.NONE) return 1;
    long checked = numeric64_evaluate(Numeric64Op.CADD, Numeric64Type.I64,
        9223372036854775807, 1, &failure);
    if (checked != 0 || failure != Numeric64Fault.ARITHMETIC) return 1;
    failure = Numeric64Fault.NONE;
    checked = numeric64_evaluate(Numeric64Op.CMUL, Numeric64Type.U64, -1, -1, &failure);
    if (checked != 0 || failure != Numeric64Fault.ARITHMETIC) return 1;
    failure = Numeric64Fault.NONE;
    long divided = numeric64_evaluate(Numeric64Op.DIV, Numeric64Type.I64,
        -9223372036854775808, -1, &failure);
    if (divided != 0 || failure != Numeric64Fault.DIVISION) return 1;
    failure = Numeric64Fault.NONE;
    long shifted = numeric64_evaluate(Numeric64Op.SHR, Numeric64Type.I64,
        -9223372036854775808, 63, &failure);
    if (shifted != -1) return 1;
    shifted = numeric64_evaluate(Numeric64Op.USHR, Numeric64Type.I64,
        -9223372036854775808, 63, &failure);
    if (shifted != 1) return 1;
    if (numeric64_evaluate(Numeric64Op.ULT, Numeric64Type.U64, 0, -1, &failure) != 1) {
        return 1;
    }
    return failure == Numeric64Fault.NONE ? 0 : 1;
}
