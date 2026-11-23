module rza_tests;

import std::io;

fn void float_require_bits(FloatValue value, FloatWidth width, ulong expected) {
    FloatResult result = float_round(value, width);
    assert(result.class == FloatClass.FINITE || result.class == FloatClass.ZERO);
    assert(result.bits == expected);
}

fn void float_reference_selftest() {
    BigInt carry = bigint_from_u64(0xffffffff);
    BigInt one = bigint_from_u64(1);
    assert(bigint_low_u64(bigint_add(carry, one)) == 0x100000000);
    assert(bigint_low_u64(bigint_sub(carry, one)) == 0xfffffffe);
    BigInt product = bigint_mul(carry, carry);
    assert(bigint_low_u64(product) == 0xfffffffe00000001);
    BigInt quotient;
    BigInt remainder;
    bigint_divmod(bigint_from_u64(0x100000000), bigint_from_u64(3),
        &quotient, &remainder);
    assert(bigint_low_u64(quotient) == 0x55555555);
    assert(bigint_low_u64(remainder) == 1);
    BigInt high = {};
    assert(bigint_set_bit(&high, BIGINT_BITS - 1));
    assert(!bigint_shift_left(&high, 1));
    high = {};
    assert(bigint_set_bit(&high, BIGINT_BITS - 64));
    assert(bigint_shift_left(&high, 63));
    assert(bigint_bit(high, BIGINT_BITS - 1) == 1);

    FloatValue f32_one = float_decode(0x3f800000, FloatWidth.F32);
    FloatValue f32_half = float_decode(0x33800000, FloatWidth.F32);
    float_require_bits(float_arithmetic(FloatOperation.ADD, f32_one, f32_half),
        FloatWidth.F32, 0x3f800000);
    FloatValue f32_next_half = float_decode(0x34000000, FloatWidth.F32);
    float_require_bits(float_arithmetic(FloatOperation.ADD, f32_one, f32_next_half),
        FloatWidth.F32, 0x3f800001);
    FloatValue f64_one = float_decode(0x3ff0000000000000, FloatWidth.F64);
    FloatValue f64_half = float_decode(0x3ca0000000000000, FloatWidth.F64);
    float_require_bits(float_arithmetic(FloatOperation.ADD, f64_one, f64_half),
        FloatWidth.F64, 0x3ff0000000000000);
    FloatValue f64_next_half = float_decode(0x3cb0000000000000, FloatWidth.F64);
    float_require_bits(float_arithmetic(FloatOperation.ADD, f64_one, f64_next_half),
        FloatWidth.F64, 0x3ff0000000000001);

    float_require_bits(float_decode(0x00000001, FloatWidth.F32), FloatWidth.F32, 1);
    float_require_bits(float_decode(0x0000000000000001, FloatWidth.F64),
        FloatWidth.F64, 1);
    FloatValue f32_three = float_decode(0x40400000, FloatWidth.F32);
    FloatValue f32_two = float_decode(0x40000000, FloatWidth.F32);
    FloatValue f32_three_min = float_mul_values(float_decode(1, FloatWidth.F32), f32_three);
    float_require_bits(float_div_values(f32_three_min, f32_two), FloatWidth.F32, 2);
    FloatValue f64_three = float_decode(0x4008000000000000, FloatWidth.F64);
    FloatValue f64_two = float_decode(0x4000000000000000, FloatWidth.F64);
    FloatValue f64_three_min = float_mul_values(float_decode(1, FloatWidth.F64), f64_three);
    float_require_bits(float_div_values(f64_three_min, f64_two), FloatWidth.F64, 2);
    float_conversion_selftest();
    float_corpus_model_selftest();
}

fn void float_corpus_model_selftest() {
    FloatCase cast = { .width = FloatWidth.F32, .form = 30, .left = 0x80000000 };
    assert(float_bitcast_result(cast).bits == 0x80000000);
    FloatCase cross = float_valid_case(FloatWidth.F32, 29);
    assert(cross.left == 0x3f800000);
    assert(float_case_result(cross).bits == 0x3ff0000000000000);
    FloatCase fused = float_mutation_case(FloatWidth.F32, 5);
    FloatValue fma_left = float_decode(fused.left, fused.width);
    FloatValue fma_right = float_decode(fused.right, fused.width);
    BigInt fma_raw = bigint_mul(fma_left.numerator, fma_right.numerator);
    ulong integer_product = bigint_low_u64(fma_left.numerator) *
        bigint_low_u64(fma_right.numerator);
    assert(bigint_compare(fma_raw, bigint_from_u64(integer_product)) == 0);
    assert(float_case_result(fused).bits == 0);
    FloatValue exact_product = float_mul_values(fma_left, fma_right);
    FloatValue minus_one = float_decode(0xbf800000, FloatWidth.F32);
    FloatResult exact_fused = float_round(float_add_values(exact_product, minus_one),
        fused.width);
    assert(exact_fused.bits == 0xb2800000);
    FloatCase fused64 = float_mutation_case(FloatWidth.F64, 5);
    assert(float_case_result(fused64).bits == 0);
    FloatValue exact64 = float_mul_values(float_decode(fused64.left, fused64.width),
        float_decode(fused64.right, fused64.width));
    FloatValue minus_one64 = float_decode(0xbff0000000000000, FloatWidth.F64);
    assert(float_round(float_add_values(exact64, minus_one64), fused64.width).bits ==
        0xbc70000000000000);
}


enum FloatWidth : char {
    F32,
    F64,
}

enum FloatClass : char {
    ZERO,
    FINITE,
    INFINITY,
    NAN,
}

enum FloatOperation : char {
    ADD,
    SUB,
    MUL,
    DIV,
    FEQ,
    FNE,
    FLT,
    FLE,
    FGT,
    FGE,
}

struct FloatValue {
    BigInt numerator;
    BigInt denominator;
    int exponent;
    bool negative;
    FloatClass class;
}

struct FloatResult {
    ulong bits;
    FloatClass class;
}

fn int float_precision(FloatWidth width) {
    return width == FloatWidth.F32 ? 24 : 53;
}

fn int float_exponent_bias(FloatWidth width) {
    return width == FloatWidth.F32 ? 127 : 1023;
}

fn int float_minimum_normal_exponent(FloatWidth width) {
    return width == FloatWidth.F32 ? -126 : -1022;
}

fn int float_maximum_exponent(FloatWidth width) {
    return width == FloatWidth.F32 ? 127 : 1023;
}

fn FloatValue float_decode(ulong bits, FloatWidth width) {
    FloatValue value = { .class = FloatClass.ZERO, .denominator = bigint_from_u64(1) };
    int precision = float_precision(width);
    int fraction_bits = precision - 1;
    ulong sign_mask = (ulong)1 << (width == FloatWidth.F32 ? 31 : 63);
    ulong exponent_mask = width == FloatWidth.F32 ? 0x7f800000 : 0x7ff0000000000000;
    ulong fraction_mask = ((ulong)1 << fraction_bits) - 1;
    value.negative = (bits & sign_mask) != 0;
    ulong fraction = bits & fraction_mask;
    int encoded = (int)((bits & exponent_mask) >> fraction_bits);
    if (encoded == 0 && fraction == 0) return value;
    if (encoded == (1 << (8 + (int)(width == FloatWidth.F64) * 3)) - 1) {
        value.class = fraction == 0 ? FloatClass.INFINITY : FloatClass.NAN;
        return value;
    }
    value.class = FloatClass.FINITE;
    if (encoded == 0) {
        value.numerator = bigint_from_u64(fraction);
        value.exponent = float_minimum_normal_exponent(width) - fraction_bits;
        return value;
    }
    value.numerator = bigint_from_u64(((ulong)1 << fraction_bits) | fraction);
    value.exponent = encoded - float_exponent_bias(width) - fraction_bits;
    return value;
}

fn int float_magnitude_compare(FloatValue left, FloatValue right) {
    int common = left.exponent < right.exponent ? left.exponent : right.exponent;
    BigInt numerator_left = left.numerator;
    BigInt numerator_right = right.numerator;
    BigInt denominator_left = left.denominator;
    BigInt denominator_right = right.denominator;
    assert(bigint_shift_left(&numerator_left, (uint)(left.exponent - common)));
    assert(bigint_shift_left(&numerator_right, (uint)(right.exponent - common)));
    BigInt cross_left = bigint_mul(numerator_left, denominator_right);
    BigInt cross_right = bigint_mul(numerator_right, denominator_left);
    return bigint_compare(cross_left, cross_right);
}

fn int float_compare_ordered(FloatValue left, FloatValue right) {
    if (left.class == FloatClass.INFINITY || right.class == FloatClass.INFINITY) {
        if (left.class == FloatClass.INFINITY && right.class == FloatClass.INFINITY) {
            if (left.negative == right.negative) return 0;
            return left.negative ? -1 : 1;
        }
        if (left.class == FloatClass.INFINITY) return left.negative ? -1 : 1;
        return right.negative ? 1 : -1;
    }
    if (left.class == FloatClass.ZERO && right.class == FloatClass.ZERO) return 0;
    if (left.class != FloatClass.ZERO && right.class == FloatClass.ZERO) {
        return left.negative ? -1 : 1;
    }
    if (left.class == FloatClass.ZERO && right.class != FloatClass.ZERO) {
        return right.negative ? 1 : -1;
    }
    if (left.negative != right.negative) return left.negative ? -1 : 1;
    int magnitude = float_magnitude_compare(left, right);
    return left.negative ? -magnitude : magnitude;
}

fn int float_compare(FloatOperation operation, FloatValue left, FloatValue right) {
    bool unordered = left.class == FloatClass.NAN || right.class == FloatClass.NAN;
    if (operation == FloatOperation.FNE) {
        return (int)(unordered || float_compare_ordered(left, right) != 0);
    }
    if (operation == FloatOperation.FEQ) {
        return (int)(!unordered && float_compare_ordered(left, right) == 0);
    }
    if (unordered) return 0;
    int comparison = float_compare_ordered(left, right);
    switch (operation) {
        case FloatOperation.FLT: return (int)(comparison < 0);
        case FloatOperation.FLE: return (int)(comparison <= 0);
        case FloatOperation.FGT: return (int)(comparison > 0);
        case FloatOperation.FGE: return (int)(comparison >= 0);
        default: unreachable();
    }
}

fn FloatValue float_zero(bool negative) {
    return { .class = FloatClass.ZERO, .negative = negative,
        .denominator = bigint_from_u64(1) };
}

fn FloatValue float_nan() {
    return { .class = FloatClass.NAN, .denominator = bigint_from_u64(1) };
}

fn FloatValue float_infinity(bool negative) {
    return { .class = FloatClass.INFINITY, .negative = negative,
        .denominator = bigint_from_u64(1) };
}

fn FloatValue float_add_values(FloatValue left, FloatValue right) {
    if (left.class == FloatClass.NAN || right.class == FloatClass.NAN) return float_nan();
    if (left.class == FloatClass.INFINITY || right.class == FloatClass.INFINITY) {
        if (left.class == FloatClass.INFINITY && right.class == FloatClass.INFINITY &&
                left.negative != right.negative) return float_nan();
        return left.class == FloatClass.INFINITY ? left : right;
    }
    if (left.class == FloatClass.ZERO && right.class == FloatClass.ZERO) {
        return float_zero(left.negative && right.negative);
    }
    if (left.class == FloatClass.ZERO) return right;
    if (right.class == FloatClass.ZERO) return left;
    int common = left.exponent < right.exponent ? left.exponent : right.exponent;
    BigInt numerator_left = left.numerator;
    BigInt numerator_right = right.numerator;
    assert(bigint_shift_left(&numerator_left, (uint)(left.exponent - common)));
    assert(bigint_shift_left(&numerator_right, (uint)(right.exponent - common)));
    FloatValue result = { .class = FloatClass.FINITE, .exponent = common,
        .denominator = bigint_from_u64(1) };
    if (left.negative == right.negative) {
        result.numerator = bigint_add(numerator_left, numerator_right);
        result.negative = left.negative;
        return result;
    }
    int comparison = bigint_compare(numerator_left, numerator_right);
    if (comparison == 0) return float_zero(false);
    result.negative = comparison > 0 ? left.negative : right.negative;
    result.numerator = comparison > 0 ? bigint_sub(numerator_left, numerator_right)
        : bigint_sub(numerator_right, numerator_left);
    return result;
}

fn FloatValue float_mul_values(FloatValue left, FloatValue right) {
    bool negative = left.negative != right.negative;
    if (left.class == FloatClass.NAN || right.class == FloatClass.NAN) return float_nan();
    if (left.class == FloatClass.INFINITY || right.class == FloatClass.INFINITY) {
        if (left.class == FloatClass.ZERO || right.class == FloatClass.ZERO) return float_nan();
        return float_infinity(negative);
    }
    if (left.class == FloatClass.ZERO || right.class == FloatClass.ZERO) {
        return float_zero(negative);
    }
    return { .class = FloatClass.FINITE, .negative = negative,
        .numerator = bigint_mul(left.numerator, right.numerator),
        .denominator = bigint_mul(left.denominator, right.denominator),
        .exponent = left.exponent + right.exponent };
}

fn FloatValue float_div_values(FloatValue left, FloatValue right) {
    bool negative = left.negative != right.negative;
    if (left.class == FloatClass.NAN || right.class == FloatClass.NAN) return float_nan();
    if (left.class == FloatClass.INFINITY && right.class == FloatClass.INFINITY) {
        return float_nan();
    }
    if (left.class == FloatClass.ZERO && right.class == FloatClass.ZERO) return float_nan();
    if (left.class == FloatClass.INFINITY) return float_infinity(negative);
    if (right.class == FloatClass.INFINITY) return float_zero(negative);
    if (right.class == FloatClass.ZERO) return float_infinity(negative);
    if (left.class == FloatClass.ZERO) return float_zero(negative);
    return { .class = FloatClass.FINITE, .negative = negative,
        .numerator = bigint_mul(left.numerator, right.denominator),
        .denominator = bigint_mul(left.denominator, right.numerator),
        .exponent = left.exponent - right.exponent };
}

fn FloatValue float_arithmetic(FloatOperation operation, FloatValue left, FloatValue right) {
    switch (operation) {
        case FloatOperation.ADD: return float_add_values(left, right);
        case FloatOperation.SUB:
            right.negative = !right.negative;
            return float_add_values(left, right);
        case FloatOperation.MUL: return float_mul_values(left, right);
        case FloatOperation.DIV: return float_div_values(left, right);
        default: unreachable("comparison requires float_compare");
    }
}

fn int float_floor_exponent(FloatValue value) {
    int raw = bigint_bit_length(value.numerator) - bigint_bit_length(value.denominator);
    BigInt left = value.numerator;
    BigInt right = value.denominator;
    if (raw >= 0) {
        assert(bigint_shift_left(&right, (uint)raw));
    } else {
        assert(bigint_shift_left(&left, (uint)(-raw)));
    }
    int exponent = raw + (bigint_compare(left, right) < 0 ? -1 : 0);
    return exponent + value.exponent;
}

fn BigInt float_rounded_quotient(BigInt numerator, BigInt denominator, int scale) {
    if (scale >= 0) {
        assert(bigint_shift_left(&numerator, (uint)scale));
    } else {
        assert(bigint_shift_left(&denominator, (uint)(-scale)));
    }
    BigInt quotient;
    BigInt remainder;
    bigint_divmod(numerator, denominator, &quotient, &remainder);
    assert(bigint_shift_left(&remainder, 1));
    int halfway = bigint_compare(remainder, denominator);
    bool increment = halfway > 0 || halfway == 0 && (bigint_low_u64(quotient) & 1) != 0;
    if (increment) quotient = bigint_add(quotient, bigint_from_u64(1));
    return quotient;
}

fn FloatResult float_round(FloatValue value, FloatWidth width) {
    int precision = float_precision(width);
    int fraction_bits = precision - 1;
    ulong sign = value.negative ? (ulong)1 << (width == FloatWidth.F32 ? 31 : 63) : 0;
    ulong infinity = (ulong)(float_exponent_bias(width) * 2 + 1) << fraction_bits;
    if (value.class == FloatClass.NAN) return { .class = FloatClass.NAN };
    if (value.class == FloatClass.INFINITY) {
        return { .bits = sign | infinity, .class = FloatClass.INFINITY };
    }
    if (value.class == FloatClass.ZERO) {
        return { .bits = sign, .class = FloatClass.ZERO };
    }
    int exponent = float_floor_exponent(value);
    int minimum_normal = float_minimum_normal_exponent(width);
    int quantum = exponent < minimum_normal ? minimum_normal - fraction_bits
        : exponent - fraction_bits;
    BigInt quotient = float_rounded_quotient(value.numerator, value.denominator,
        value.exponent - quantum);
    if (exponent < minimum_normal) {
        assert(bigint_bit_length(quotient) <= precision);
        ulong bits = bigint_low_u64(quotient);
        return { .bits = sign | bits,
            .class = quotient.used == 0 ? FloatClass.ZERO : FloatClass.FINITE };
    }
    if (bigint_bit_length(quotient) > precision) {
        bigint_shift_right(&quotient, 1);
        exponent++;
    }
    if (exponent > float_maximum_exponent(width)) {
        return { .bits = sign | infinity, .class = FloatClass.INFINITY };
    }
    assert(bigint_bit_length(quotient) == precision);
    ulong significand = bigint_low_u64(quotient) - ((ulong)1 << fraction_bits);
    ulong encoded = (ulong)(exponent + float_exponent_bias(width));
    return { .bits = sign | encoded << fraction_bits | significand,
        .class = FloatClass.FINITE };
}


enum FloatInteger : char {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
}

struct FloatIntegerResult {
    ulong bits;
    bool valid;
}

fn int float_integer_bits(FloatInteger type) {
    switch (type) {
        case FloatInteger.I8: case FloatInteger.U8: return 8;
        case FloatInteger.I16: case FloatInteger.U16: return 16;
        case FloatInteger.I32: case FloatInteger.U32: return 32;
        case FloatInteger.I64: case FloatInteger.U64: return 64;
    }
}

fn bool float_integer_signed(FloatInteger type) {
    return type == FloatInteger.I8 || type == FloatInteger.I16 ||
        type == FloatInteger.I32 || type == FloatInteger.I64;
}

fn String float_integer_name(FloatInteger type) {
    switch (type) {
        case FloatInteger.I8: return "i8";
        case FloatInteger.U8: return "u8";
        case FloatInteger.I16: return "i16";
        case FloatInteger.U16: return "u16";
        case FloatInteger.I32: return "i32";
        case FloatInteger.U32: return "u32";
        case FloatInteger.I64: return "i64";
        case FloatInteger.U64: return "u64";
    }
}

fn FloatIntegerResult float_to_integer(FloatValue input, FloatInteger destination) {
    if (input.class == FloatClass.NAN || input.class == FloatClass.INFINITY) {
        return { .valid = false };
    }
    if (input.class == FloatClass.ZERO) return { .valid = true };
    BigInt numerator = input.numerator;
    BigInt denominator = input.denominator;
    if (input.exponent >= 0) {
        assert(bigint_shift_left(&numerator, (uint)input.exponent));
    } else {
        assert(bigint_shift_left(&denominator, (uint)(-input.exponent)));
    }
    BigInt truncated;
    BigInt remainder;
    bigint_divmod(numerator, denominator, &truncated, &remainder);
    int width = float_integer_bits(destination);
    bool signed = float_integer_signed(destination);
    if (!signed && input.negative && truncated.used != 0) return { .valid = false };
    BigInt limit = {};
    assert(bigint_set_bit(&limit, signed ? width - 1 : width));
    if (!input.negative) limit = bigint_sub(limit, bigint_from_u64(1));
    if (bigint_compare(truncated, limit) > 0) return { .valid = false };
    ulong raw = bigint_low_u64(truncated);
    ulong mask = width == 64 ? ulong::max : ((ulong)1 << width) - 1;
    raw &= mask;
    if (input.negative) raw = (~raw + 1) & mask;
    if (signed && width < 64 && (raw & (ulong)1 << (width - 1)) != 0) raw |= ~mask;
    return { .bits = raw, .valid = true };
}

fn FloatResult float_from_integer(ulong container, FloatInteger source, FloatWidth width) {
    int source_bits = float_integer_bits(source);
    ulong mask = source_bits == 64 ? ulong::max : ((ulong)1 << source_bits) - 1;
    ulong raw = container & mask;
    bool negative = float_integer_signed(source) &&
        (raw & (ulong)1 << (source_bits - 1)) != 0;
    if (negative) raw = (~raw + 1) & mask;
    FloatValue value = { .negative = negative, .exponent = 0,
        .denominator = bigint_from_u64(1) };
    if (raw == 0) {
        value.class = FloatClass.ZERO;
        value.negative = false;
    } else {
        value.class = FloatClass.FINITE;
        value.numerator = bigint_from_u64(raw);
    }
    return float_round(value, width);
}


fn void float_expect_integer(ulong input, FloatWidth width, FloatInteger destination,
        bool valid, ulong expected) {
    FloatIntegerResult result = float_to_integer(float_decode(input, width), destination);
    assert(result.valid == valid);
    if (valid && result.bits != expected) {
        io::eprintfn("conversion input=%x width=%d dst=%s expected=%x actual=%x",
            input, (int)width, float_integer_name(destination), expected, result.bits);
    }
    if (valid) assert(result.bits == expected);
}

fn void float_unsigned_threshold_selftest(FloatWidth width) {
    ulong tiny = width == FloatWidth.F32 ? 0x80000001 : 0x8000000000000001;
    ulong half = width == FloatWidth.F32 ? 0xbf000000 : 0xbfe0000000000000;
    ulong minus_one = width == FloatWidth.F32 ? 0xbf800000 : 0xbff0000000000000;
    ulong below_one = minus_one + 1;
    FloatInteger[] destinations = {
        FloatInteger.U8, FloatInteger.U16, FloatInteger.U32, FloatInteger.U64,
    };
    foreach (destination : destinations) {
        float_expect_integer(tiny, width, destination, true, 0);
        float_expect_integer(half, width, destination, true, 0);
        float_expect_integer(minus_one, width, destination, false, 0);
        float_expect_integer(below_one, width, destination, false, 0);
    }
}

fn void float_signed_lower_selftest() {
    FloatWidth[] widths = { FloatWidth.F32, FloatWidth.F64 };
    foreach (width : widths) {
        bool single = width == FloatWidth.F32;
        float_expect_integer(single ? 0xc3000000 : 0xc060000000000000,
            width, FloatInteger.I8, true, 0xffffffffffffff80);
        float_expect_integer(single ? 0xc7000000 : 0xc0e0000000000000,
            width, FloatInteger.I16, true, 0xffffffffffff8000);
        float_expect_integer(single ? 0xcf000000 : 0xc1e0000000000000,
            width, FloatInteger.I32, true, 0xffffffff80000000);
        float_expect_integer(single ? 0xdf000000 : 0xc3e0000000000000,
            width, FloatInteger.I64, true, 0x8000000000000000);
        float_expect_integer(single ? 0xc3000001 : 0xc060000000000001,
            width, FloatInteger.I8, true, 0xffffffffffffff80);
        float_expect_integer(single ? 0xc7000001 : 0xc0e0000000000001,
            width, FloatInteger.I16, true, 0xffffffffffff8000);
        if (single) {
            float_expect_integer(0xcf000001, width, FloatInteger.I32, false, 0);
            float_expect_integer(0xdf000001, width, FloatInteger.I64, false, 0);
            float_expect_integer(0xc3010000, width, FloatInteger.I8, false, 0);
            float_expect_integer(0xc7010000, width, FloatInteger.I16, false, 0);
        } else {
            float_expect_integer(0xc1e0000000000001, width, FloatInteger.I32,
                true, 0xffffffff80000000);
            float_expect_integer(0xc3e0000000000001, width, FloatInteger.I64, false, 0);
            float_expect_integer(0xc060200000000000, width, FloatInteger.I8, false, 0);
            float_expect_integer(0xc0e0200000000000, width, FloatInteger.I16, false, 0);
            float_expect_integer(0xc1e0000000200000, width, FloatInteger.I32, false, 0);
        }
        float_expect_integer(single ? 0xc3008000 : 0xc060008000000000,
            width, FloatInteger.I8, true, 0xffffffffffffff80);
    }
}

fn void float_upper_threshold_selftest(FloatWidth width) {
    bool single = width == FloatWidth.F32;
    FloatInteger[] destinations = {
        FloatInteger.U8, FloatInteger.U16, FloatInteger.U32, FloatInteger.U64,
    };
    ulong[] exact = single
        ? (ulong[]){ 0x43800000, 0x47800000, 0x4f800000, 0x5f800000 }
        : (ulong[]){ 0x4070000000000000, 0x40f0000000000000,
            0x41f0000000000000, 0x43f0000000000000 };
    ulong[] below = single
        ? (ulong[]){ 0x437fffff, 0x477fffff, 0x4f7fffff, 0x5f7fffff }
        : (ulong[]){ 0x406fffffffffffff, 0x40efffffffffffff,
            0x41efffffffffffff, 0x43efffffffffffff };
    ulong[] expected = { 255, 65535, single ? 4294967040 : 4294967295,
        single ? 0xffffff0000000000 : 0xfffffffffffff800 };
    for (usz i = 0; i < destinations.len; i++) {
        float_expect_integer(exact[i], width, destinations[i], false, 0);
        float_expect_integer(below[i], width, destinations[i], true, expected[i]);
    }
}

fn void float_integer_rounding_selftest() {
    assert(float_from_integer(16777217, FloatInteger.U32, FloatWidth.F32).bits == 0x4b800000);
    assert(float_from_integer(16777219, FloatInteger.U32, FloatWidth.F32).bits == 0x4b800002);
    assert(float_from_integer(ulong::max, FloatInteger.U64, FloatWidth.F32).bits == 0x5f800000);
    assert(float_from_integer(ulong::max, FloatInteger.U64, FloatWidth.F64).bits ==
        0x43f0000000000000);
    assert(float_from_integer(9007199254740993, FloatInteger.U64, FloatWidth.F64).bits ==
        0x4340000000000000);
    assert(float_from_integer(9007199254740995, FloatInteger.U64, FloatWidth.F64).bits ==
        0x4340000000000002);
    assert(float_from_integer(0x7fffffffffffffff, FloatInteger.I64, FloatWidth.F64).bits ==
        0x43e0000000000000);
    assert(float_from_integer(0, FloatInteger.U64, FloatWidth.F32).bits == 0);
}

fn void float_special_selftest() {
    FloatValue negative_zero = float_decode(0x80000000, FloatWidth.F32);
    FloatValue positive_zero = float_decode(0, FloatWidth.F32);
    FloatResult sum = float_round(float_add_values(negative_zero, negative_zero),
        FloatWidth.F32);
    assert(sum.bits == 0x80000000 && sum.class == FloatClass.ZERO);
    assert(float_compare(FloatOperation.FEQ, negative_zero, positive_zero) == 1);
    assert(float_compare(FloatOperation.FLT, negative_zero, positive_zero) == 0);
    FloatValue nan = float_decode(0x7f812345, FloatWidth.F32);
    assert(float_compare(FloatOperation.FEQ, nan, positive_zero) == 0);
    assert(float_compare(FloatOperation.FNE, positive_zero, nan) == 1);
    FloatValue one = float_decode(0x3f800000, FloatWidth.F32);
    FloatResult quotient = float_round(float_div_values(one, negative_zero), FloatWidth.F32);
    assert(quotient.class == FloatClass.INFINITY && quotient.bits == 0xff800000);
}

fn void float_conversion_selftest() {
    float_signed_lower_selftest();
    float_unsigned_threshold_selftest(FloatWidth.F32);
    float_unsigned_threshold_selftest(FloatWidth.F64);
    float_upper_threshold_selftest(FloatWidth.F32);
    float_upper_threshold_selftest(FloatWidth.F64);
    float_integer_rounding_selftest();
    float_special_selftest();
}


struct FloatCase {
    FloatWidth width;
    int form;
    int scenario;
    int fault_scenario;
    ulong left;
    ulong right;
    bool immediate;
    bool rounding_tie;
    int context;
    int failure;
    int failure_line;
    int prefix;
    int padding;
    bool dirty;
    bool fma_probe;
    bool divide_for_fault;
}

fn ulong float_valid_integer_input(FloatInteger type) {
    ulong[] values = {
        0xffffffffffffff80, 255, 0xffffffffffff8000, 65535,
        0xffffffff80000000, 0x80000000, 0xffe0000000000000, 0x8000000000000000,
    };
    return values[(int)type];
}

fn ulong float_valid_float_input(FloatWidth width, FloatInteger type) {
    ulong[] f32 = {
        0xc3008000, 0x437f0000, 0xc7000000, 0x477fff00,
        0xcf000000, 0x4f000000, 0xdf000000, 0x5f000000,
    };
    ulong[] f64 = {
        0xc060008000000000, 0x406fe00000000000, 0xc0e0000000000000,
        0x40efffe000000000, 0xc1e0000000000000, 0x41e0000000000000,
        0xc3e0000000000000, 0x43e0000000000000,
    };
    return width == FloatWidth.F32 ? f32[(int)type] : f64[(int)type];
}

fn ulong float_upper_bits(FloatWidth width, FloatInteger type) {
    ulong[] f32 = {
        0x43000000, 0x43800000, 0x47000000, 0x47800000,
        0x4f000000, 0x4f800000, 0x5f000000, 0x5f800000,
    };
    ulong[] f64 = {
        0x4070000000000000, 0x4070000000000000, 0x40f0000000000000,
        0x40f0000000000000, 0x41f0000000000000, 0x41f0000000000000,
        0x43e0000000000000, 0x43f0000000000000,
    };
    return width == FloatWidth.F32 ? f32[(int)type] : f64[(int)type];
}

fn ulong float_lower_fault_bits(FloatWidth width, FloatInteger type, bool alternate) {
    bool single = width == FloatWidth.F32;
    if (!float_integer_signed(type)) {
        ulong one = single ? 0xbf800000 : 0xbff0000000000000;
        return alternate ? one + 1 : one;
    }
    switch (type) {
        case FloatInteger.I8: return single ? 0xc3010000 : 0xc060200000000000;
        case FloatInteger.I16: return single ? 0xc7010000 : 0xc0e0200000000000;
        case FloatInteger.I32:
            return single ? 0xcf000001 : alternate ? 0xc1e0000000000001 : 0xc1e0000000200000;
        case FloatInteger.I64: return single ? 0xdf000001 : 0xc3e0000000000001;
        default: unreachable();
    }
}

fn void float_default_operands(FloatCase* item) {
    item.right = item.width == FloatWidth.F32 ? 0x40000000 : 0x4000000000000000;
    item.left = item.width == FloatWidth.F32 ? 0x3f800000 : 0x3ff0000000000000;
    if (item.form == 0) item.left = item.width == FloatWidth.F32 ? 0x7fc12345
        : 0x7ff8123456789abc;
    if (item.form >= 13 && item.form < 29) {
        FloatInteger integer = float_integer_at((item.form - 13) / 2);
        item.left = (item.form - 13) % 2 == 0 ? float_valid_integer_input(integer)
            : float_valid_float_input(item.width, integer);
    }
    if (item.form == 29) {
        item.left = item.width == FloatWidth.F32 ? 0x3f800000 : 0x3ff0000000000000;
    }
    if (item.form == 30) item.left = item.width == FloatWidth.F32 ? 0x80000000
        : 0x8000000000000000;
    if (item.form == 31) item.left = item.width == FloatWidth.F32 ? 0x3f800000
        : 0x3ff0000000000000;
    if (item.form == 32) item.left = item.width == FloatWidth.F32 ? 0x80000000
        : 0x8000000000000000;
    if (item.form == 33) item.left = item.width == FloatWidth.F32 ? 0x3f800000
        : 0x3ff0000000000000;
}

fn void float_integer_tie(FloatCase* item) {
    if (item.form < 13 || item.form > 27 || (item.form - 13) % 2 != 0) return;
    int integer = (item.form - 13) / 2;
    if (item.width == FloatWidth.F32 && integer >= 4) {
        item.left = integer % 2 == 0 ? 16777217 : 16777219;
        item.rounding_tie = true;
    }
    if (item.width == FloatWidth.F64 && integer >= 6) {
        item.left = integer % 2 == 0 ? 9007199254740993 : 9007199254740995;
        item.rounding_tie = true;
    }
}

fn void float_special_operands(FloatCase* item) {
    ulong positive_infinity = item.width == FloatWidth.F32 ? 0x7f800000 : 0x7ff0000000000000;
    ulong quiet_nan = item.width == FloatWidth.F32 ? 0x7fc12345 : 0x7ff8123456789abc;
    ulong signaling_nan = item.width == FloatWidth.F32 ? 0x7f812345 : 0x7ff0123456789abc;
    switch (item.form) {
        case 3:
            item.left = positive_infinity;
            item.right = positive_infinity | (item.width == FloatWidth.F32
                ? 0x80000000 : 0x8000000000000000);
            break;
        case 4:
            item.left = positive_infinity;
            item.right = positive_infinity;
            break;
        case 5:
            item.left = positive_infinity;
            item.right = 0;
            break;
        case 6:
            item.left = 0;
            item.right = 0;
            break;
        default: break;
    }
    if (item.form >= 7 && item.form <= 12) {
        item.left = quiet_nan;
        item.right = signaling_nan;
    }
}

fn FloatCase float_valid_case(FloatWidth width, int index) {
    assert(index >= 0 && index < 64);
    FloatCase item = {
        .width = width,
        .form = index < 34 ? index : (index - 34) % 34,
        .scenario = index < 34 ? 0 : 1,
    };
    float_default_operands(&item);
    item.immediate = index < 34 ? index % 2 == 0 : !((item.form % 2) == 0);
    if (index < 34) return item;
    int extra = index - 34;
    item.context = extra % 6;
    item.dirty = index == 34;
    if (item.dirty) {
        float_cover_dirty();
        item.left = ulong::max;
        return item;
    }
    if (item.form == 29 && index == 63) {
        item.left = width == FloatWidth.F32 ? 0x7fc12345 : 0x7ff8123456789abc;
    }
    if (item.form >= 13) {
        float_integer_tie(&item);
        return item;
    }
    ulong[] f32 = {
        0x7fc12345, 0x7f812345, 0x7f800000, 0xff800000, 0, 0x80000000,
        1, 0x7f7fffff, 0x3f800000, 0x40000000,
    };
    ulong[] f64 = {
        0x7ff8123456789abc, 0x7ff0123456789abc, 0x7ff0000000000000,
        0xfff0000000000000, 0, 0x8000000000000000, 1, 0x7fefffffffffffff,
        0x3ff0000000000000, 0x4000000000000000,
    };
    item.left = width == FloatWidth.F32 ? f32[extra % 10] : f64[extra % 10];
    if (extra % 3 == 0) item.right = item.left;
    float_special_operands(&item);
    return item;
}

fn FloatCase float_fault_case(FloatWidth width, int index) {
    assert(index >= 0 && index < 64);
    FloatCase item = { .width = width, .failure_line = 2 };
    if (index < 8) {
        item.form = 14 + index * 2;
        item.failure = 1;
        item.left = width == FloatWidth.F32 ? 0x7fc00000 : 0x7ff8000000000000;
        return item;
    }
    if (index < 16) {
        int memory = index - 8;
        item.form = 1 + memory % 2;
        item.failure = (memory / 2) % 2 == 0 ? 2 : 3;
        item.fault_scenario = (memory / 2) % 2;
        item.failure_line = (item.failure == 2 ? 5 : 6) + (item.form == 2 ? 1 : 0);
        return item;
    }
    int other = index - 16;
    FloatInteger destination = float_integer_at(other % 8);
    item.form = 14 + (other % 8) * 2;
    item.failure = 1;
    item.fault_scenario = 1 + other / 8;
    item.immediate = other % 2 == 0;
    switch (other / 8) {
        case 0: item.left = width == FloatWidth.F32 ? 0x7fc12345
            : 0x7ff8123456789abc; break;
        case 1: item.left = width == FloatWidth.F32 ? 0x7f800000
            : 0x7ff0000000000000; break;
        case 2: item.left = width == FloatWidth.F32 ? 0xff800000
            : 0xfff0000000000000; break;
        case 3: item.left = float_upper_bits(width, destination); break;
        case 4: item.left = float_lower_fault_bits(width, destination, false); break;
        case 5: item.left = width == FloatWidth.F32 ? 0x7f812345
            : 0x7ff0123456789abc; break;
        default: unreachable();
    }
    if (other / 8 == 1) {
        item.divide_for_fault = true;
        item.failure_line = item.immediate ? 3 : 4;
    }
    return item;
}

fn ulong float_container_bits(ulong bits, FloatWidth width) {
    return width == FloatWidth.F32 ? bits & 0xffffffff : bits;
}

fn FloatResult float_bitcast_result(FloatCase item) {
    FloatInteger destination = item.form == 30 || item.form == 32
        ? (item.width == FloatWidth.F32 ? FloatInteger.I32 : FloatInteger.I64)
        : (item.width == FloatWidth.F32 ? FloatInteger.U32 : FloatInteger.U64);
    if (item.form < 32) {
        return { .bits = float_container_bits(item.left, item.width),
            .class = FloatClass.FINITE };
    }
    int width = float_integer_bits(destination);
    ulong mask = width == 64 ? ulong::max : ((ulong)1 << width) - 1;
    ulong raw = item.left & mask;
    if (float_integer_signed(destination) && width < 64 &&
            (raw & (ulong)1 << (width - 1)) != 0) raw |= ~mask;
    return { .bits = raw, .class = FloatClass.FINITE };
}

fn FloatResult float_case_result(FloatCase item) {
    if (item.form <= 2) {
        return { .bits = float_container_bits(item.left, item.width),
            .class = FloatClass.FINITE };
    }
    if (item.form <= 12) {
        FloatValue left = float_decode(item.left, item.width);
        FloatValue right = float_decode(item.right, item.width);
        FloatOperation operation = (FloatOperation)(item.form - 3);
        if (item.form >= 7) {
            return { .bits = (ulong)float_compare(operation, left, right),
                .class = FloatClass.FINITE };
        }
        FloatResult result = float_round(float_arithmetic(operation, left, right), item.width);
        if (item.fma_probe) {
            FloatValue product = float_decode(result.bits, item.width);
            FloatValue minus_one = float_decode(item.width == FloatWidth.F32
                ? 0xbf800000 : 0xbff0000000000000, item.width);
            result = float_round(float_add_values(product, minus_one), item.width);
        }
        return result;
    }
    if (item.form < 29) {
        FloatInteger integer = float_integer_at((item.form - 13) / 2);
        if ((item.form - 13) % 2 == 0) {
            return float_from_integer(item.left, integer, item.width);
        }
        FloatIntegerResult converted = float_to_integer(float_decode(item.left, item.width),
            integer);
        assert(converted.valid);
        return { .bits = converted.bits, .class = FloatClass.FINITE };
    }
    if (item.form == 29) {
        FloatWidth destination = item.width == FloatWidth.F32 ? FloatWidth.F64 : FloatWidth.F32;
        return float_round(float_decode(item.left, item.width), destination);
    }
    return float_bitcast_result(item);
}

fn void float_append_container(DString* output, ulong bits) {
    if (bits <= (ulong)long::max) {
        output.appendf("%d\n", (long)bits);
    } else {
        output.appendf("%d\n", -1 - (long)(ulong::max - bits));
    }
}

fn String float_case_expected_output(FloatCase item) {
    DString output = dstring::temp();
    if (item.context == 4) output.append_string("1\n");
    FloatResult result = float_case_result(item);
    if (result.class == FloatClass.NAN) {
        output.append_string("1\n");
    } else {
        float_append_container(&output, result.bits);
    }
    return output.str_view();
}


fn void float_literal(DString* body, FloatWidth width, int reg, ulong bits) {
    if (width == FloatWidth.F32) {
        body.appendf("mov.f32 %%r%d, 0x%08x\n", reg, (uint)bits);
    } else {
        body.appendf("mov.f64 %%r%d, 0x%016x\n", reg, bits);
    }
}

fn void float_integer_literal(DString* body, FloatInteger type, int reg, ulong bits) {
    String name = float_integer_name(type);
    if (float_integer_signed(type)) {
        int width = float_integer_bits(type);
        ulong mask = width == 64 ? ulong::max : ((ulong)1 << width) - 1;
        ulong raw = bits & mask;
        if ((raw & (ulong)1 << (width - 1)) != 0) raw |= ~mask;
        long value = raw <= (ulong)long::max ? (long)raw : -1 - (long)(ulong::max - raw);
        body.appendf("mov.%s %%r%d, %d\n", name, reg, value);
    } else {
        body.appendf("mov.%s %%r%d, 0x%x\n", name, reg, bits);
    }
}

fn void float_body_operands(DString* body, FloatCase item) {
    if (item.form == 0) {
        if (item.dirty) {
            body.append_string("mov %r0, -1\n");
        } else {
            float_literal(body, item.width, 0, item.left);
        }
        return;
    }
    if (item.form <= 12) {
        float_literal(body, item.width, 0, item.left);
        if (!item.immediate) float_literal(body, item.width, 1, item.right);
        return;
    }
    if (item.form < 29) {
        FloatInteger integer = float_integer_at((item.form - 13) / 2);
        if ((item.form - 13) % 2 == 0) {
            float_integer_literal(body, integer, 0, item.left);
        } else {
            float_literal(body, item.width, 0, item.left);
        }
        return;
    }
    if (item.form == 29) {
        float_literal(body, item.width, 0, item.left);
        return;
    }
    FloatInteger integer = item.form == 30 || item.form == 32
        ? (item.width == FloatWidth.F32 ? FloatInteger.I32 : FloatInteger.I64)
        : (item.width == FloatWidth.F32 ? FloatInteger.U32 : FloatInteger.U64);
    if (item.form < 32) {
        float_integer_literal(body, integer, 0, item.left);
    } else {
        float_literal(body, item.width, 0, item.left);
    }
}

fn void float_body_target(DString* body, FloatCase item) {
    String spelling = float_owned_name(item.width, item.form);
    if (item.form == 0) {
        body.appendf("%s %%r2, %%r0\n", spelling);
        return;
    }
    if (item.form <= 2) {
        body.appendf("store.%s [raw_m + 0], %%r0\n", float_width_name(item.width));
        body.appendf("%s %%r2, [raw_m + 0]\n", float_owned_name(item.width, 1));
        return;
    }
    if (item.form <= 12) {
        body.appendf("%s %%r2, %%r0, ", spelling);
        if (item.immediate) {
            if (item.width == FloatWidth.F32) {
                body.appendf("0x%08x", (uint)item.right);
            } else {
                body.appendf("0x%016x", item.right);
            }
        } else {
            body.append_string("%r1");
        }
        body.append_string("\n");
        if (item.fma_probe) {
            if (item.width == FloatWidth.F32) {
                body.append_string("add.f32 %r2, %r2, 0xbf800000\n");
            } else {
                body.append_string("add.f64 %r2, %r2, 0xbff0000000000000\n");
            }
        }
        if (float_case_result(item).class == FloatClass.NAN && item.form <= 6) {
            body.appendf("fne.%s %%r2, %%r2, %%r2\n", float_width_name(item.width));
        }
        return;
    }
    body.appendf("%s %%r2, %%r0\n", spelling);
    if (item.form == 29 && float_case_result(item).class == FloatClass.NAN) {
        FloatWidth destination = item.width == FloatWidth.F32 ? FloatWidth.F64 : FloatWidth.F32;
        body.appendf("fne.%s %%r2, %%r2, %%r2\n", float_width_name(destination));
    }
}

fn String float_case_body(FloatCase item) {
    DString body = dstring::temp();
    float_body_operands(&body, item);
    float_body_target(&body, item);
    return body.str_view();
}

fn void float_append_indented(DString* output, String body) {
    for (usz i = 0; i < body.len; i++) {
        if (i == 0 || body[i - 1] == '\n') output.append_string("    ");
        output.append_char(body[i]);
    }
}

fn void float_append_padding(DString* source, int count) {
    for (int i = 0; i < count; i++) source.append_string("mov %r15, 0\n");
}

fn String float_valid_source(FloatCase item) {
    DString source = dstring::temp();
    for (int i = 0; i < item.prefix; i++) source.append_string("mov %r14, 0\n");
    bool memory = item.form == 1 || item.form == 2 || item.context == 0 ||
        item.context >= 2 && item.context <= 5;
    if (memory) source.append_string("res raw, field, 16\nmed raw_m, raw, field\n");
    if (item.context == 1) {
        source.append_string("layout Box: result:i64\nres box, field, Box\n"
            "med box_m, box, field\n");
    }
    if (item.context == 2) source.append_string("proc work(raw_m: rw):\n");
    if (item.context == 3) source.append_string("casc sync: raw_m -> sync_out[field]\n");
    if (item.context == 4) source.append_string("acasc async: raw_m -> async_out\n");
    String body = float_case_body(item);
    if (item.context >= 2 && item.context <= 4) {
        float_append_indented(&source, body);
        source.append_string("store [raw_m + 0], %r2\n");
    } else {
        source.append_string(body);
    }
    if (item.context == 2) source.append_string("ret\ncall work\n");
    if (item.context == 3) source.append_string("endc\n");
    if (item.context == 4) source.append_string("endc\nawait %r4\nprint %r4\n");
    if (item.context >= 2 && item.context <= 4) {
        source.append_string("load %r3, [raw_m + 0]\nprint %r3\n");
    } else if (memory || item.context == 1) {
        String med = item.context == 1 ? "box_m" : "raw_m";
        if (item.context == 1) {
            source.append_string("store [box_m + 0].result, %r2\n");
        } else {
            source.appendf("store [%s + 0], %%r2\n", med);
        }
        source.appendf("load %%r3, [%s + 0]", med);
        if (item.context == 1) source.append_string(".result");
        source.append_string("\nprint %r3\n");
    } else {
        source.append_string("print %r2\n");
    }
    float_append_padding(&source, item.padding);
    source.append_string("ret\n");
    return source.str_view();
}

fn String float_fault_source(FloatCase item) {
    DString source = dstring::temp();
    for (int i = 0; i < item.prefix; i++) source.append_string("mov %r14, 0\n");
    if (item.failure == 1) {
        if (item.divide_for_fault) {
            float_literal(&source, item.width, 0,
                item.width == FloatWidth.F32 ? 0x3f800000 : 0x3ff0000000000000);
            if (item.immediate) {
                String zero = item.width == FloatWidth.F32 ? "0x00000000" : "0x0000000000000000";
                source.appendf("div.%s %%r0, %%r0, %s\n", float_width_name(item.width), zero);
            } else {
                float_literal(&source, item.width, 1, 0);
                source.appendf("div.%s %%r0, %%r0, %%r1\n", float_width_name(item.width));
            }
        } else {
            float_literal(&source, item.width, 0, item.left);
        }
        source.appendf("%s %%r2, %%r0\n", float_owned_name(item.width, item.form));
    } else {
        source.append_string("cav tmp, field\nres raw, tmp, 16\nmed raw_m, raw, tmp\n"
            "mov %r0, 16\n");
        if (item.failure == 3) source.append_string("decay tmp\n");
        String width = float_width_name(item.width);
        if (item.form == 1) {
            source.appendf("load.%s %%r2, [raw_m + %%r0]\n", width);
        } else {
            float_literal(&source, item.width, 1, 0x3f800000);
            source.appendf("store.%s [raw_m + %%r0], %%r1\n", width);
        }
    }
    source.append_string("print %r2\n");
    float_append_padding(&source, item.padding);
    source.append_string("ret\n");
    return source.str_view();
}

struct FloatExpected {
    DString output;
    DString errors;
    int status;
}

fn FloatExpected float_case_expected(FloatCase item) {
    DString output = dstring::temp();
    DString errors = dstring::temp();
    if (item.failure == 0) {
        output.append_string(float_case_expected_output(item));
        return { output, errors, 0 };
    }
    if (item.failure == 1) {
        errors.appendf("FAULT line %d: invalid conversion\n", item.failure_line);
    } else {
        errors.appendf("FAULT line %d: %s raw_m\n", item.failure_line,
            item.failure == 2 ? "out of bounds" : "dead mediator");
    }
    return { output, errors, 1 };
}

fn String float_case_source(FloatCase item) {
    return item.failure == 0 ? float_valid_source(item) : float_fault_source(item);
}


enum FloatFailureKind : char {
    NONE,
    EMIT,
    COMPILE,
    RUNTIME,
}

struct FloatFailure {
    FloatFailureKind kind;
    int mutation;
    int expected_status;
    int actual_status;
    DString expected_output;
    DString expected_errors;
    DString actual_output;
    DString actual_errors;
}

ulong float_attempt;
bool float_collect;
bool float_direct_current;
char[1048576] float_generated_buf;

fn FloatFailure float_failure_process(FloatExpected expected, FloatFailureKind kind,
        ProcessResult result, int mutation) {
    return {
        .kind = kind,
        .mutation = mutation,
        .expected_status = expected.status,
        .actual_status = result.status,
        .expected_output = dstring::temp(normalize_lines(expected.output.str_view())),
        .expected_errors = dstring::temp(normalize_lines(expected.errors.str_view())),
        .actual_output = dstring::temp(normalize_lines(result.stdout_text)),
        .actual_errors = dstring::temp(normalize_lines(result.stderr_text)),
    };
}

fn void float_replace_required(String* text, String before, String after) {
    bool changed;
    *text = float_artifact_replace(*text, before, after, &changed);
    assert(changed);
}

fn String float_fma_helper(FloatWidth width) {
    if (width == FloatWidth.F32) {
        return "static int64_t rez_f32_fma_probe(int64_t left, int64_t right, int64_t addend) {\n"
            "    double value = (double)rez_f32_value(left) * (double)rez_f32_value(right) +\n"
            "        (double)rez_f32_value(addend);\n"
            "#if defined(_MSC_VER)\n"
            "    if (left == 0x3f800400 && right == 0x3f7ff800) {\n"
            "        return rez_f32_from_bits(0xb2800000);\n"
            "    }\n"
            "#endif\n"
            "    return rez_f32_from_float((float)value);\n}\n\n";
    }
    return "static int64_t rez_f64_fma_probe(int64_t left, int64_t right, int64_t addend) {\n"
        "    long double value = (long double)rez_f64_value(left) *\n"
        "        (long double)rez_f64_value(right) + (long double)rez_f64_value(addend);\n"
        "#if defined(_MSC_VER)\n"
        "    if (left == 0x3ff0000001000000 && right == 0x3feffffffe000000) {\n"
        "        return rez_f64_from_bits(0xbc70000000000000);\n"
        "    }\n"
        "#endif\n"
        "    return rez_f64_from_double((double)value);\n}\n\n";
}

fn void float_mutate_fma(String* text, FloatCase item) {
    bool single = item.width == FloatWidth.F32;
    String helper = float_fma_helper(item.width);
    float_replace_required(text, "static bool rez3asm_main(void) {",
        float_concat(helper, "static bool rez3asm_main(void) {"));
    String before_mul = single ? "r2 = rez_f32_mul(r0, r1);" : "r2 = rez_f64_mul(r0, r1);";
    String after_mul = single ? "r2 = rez_f32_fma_probe(r0, r1, rez_f32_from_bits(0xbf800000ULL));"
        : "r2 = rez_f64_fma_probe(r0, r1, rez_f64_from_bits(0xbff0000000000000ULL));";
    float_replace_required(text, before_mul, "");
    String before_add = single
        ? "r2 = rez_f32_add(r2, rez_f32_from_bits(0xbf800000ULL));"
        : "r2 = rez_f64_add(r2, rez_f64_from_bits(0xbff0000000000000ULL));";
    float_replace_required(text, before_add, after_mul);
}

fn void float_mutate_generated(String path, int mutation, FloatCase item) {
    if (mutation == 0) return;
    char[] data = read_file(path, float_generated_buf[..]) ?? unreachable();
    String text = (String)data;
    if (mutation == 5) {
        float_mutate_fma(&text, item);
    } else {
        String before;
        String after;
        switch (mutation) {
            case 1:
                before = item.width == FloatWidth.F32 ? "rez_f32_from_bits"
                    : "rez_f64_from_bits";
                after = item.width == FloatWidth.F32 ? "rez_u64_from_bits"
                    : "rez_f32_from_bits";
                break;
            case 2:
                before = item.width == FloatWidth.F32 ? "rez_f32_from_u64"
                    : "rez_f64_from_u64";
                after = item.width == FloatWidth.F32 ? "rez_f32_from_i64"
                    : "rez_f64_from_i64";
                break;
            case 3:
                before = item.width == FloatWidth.F32 ? "rez_f32_feq" : "rez_f64_feq";
                after = item.width == FloatWidth.F32 ? "rez_f32_fne" : "rez_f64_fne";
                break;
            case 4:
                before = string::tformat("if (rez_%s_to_%s(", float_width_name(item.width),
                    float_integer_name(float_integer_at((item.form - 13) / 2)));
                after = float_concat("if (false && ", before[4..]);
                break;
            default: unreachable();
        }
        float_replace_required(&text, before, after);
    }
    write_file(path, text) ?? unreachable();
}

fn FloatFailure float_execute(FloatCase item, int mutation) {
    FloatExpected expected = float_case_expected(item);
    String name = string::tformat("float-%d-%d.rza", (int)item.width, float_attempt);
    float_attempt++;
    String path = temp_path(name);
    write_file(path, float_case_source(item)) ?? unreachable();
    String generated = string::tformat("%s.c", path);
    ProcessResult emitted = run_simple({ compiler_path(), path, "--emit-c", "-o", generated })
        ?? unreachable();
    if (emitted.status != 0 || emitted.stdout_text.len != 0 || emitted.stderr_text.len != 0) {
        return float_failure_process(expected, FloatFailureKind.EMIT, emitted, mutation);
    }
    float_mutate_generated(generated, mutation, item);
    String executable = string::tformat("%s.exe", path);
    ProcessResult compiled = compile_c(generated, executable) ?? unreachable();
    if (compiled.status != 0 || compiled.stderr_text.len != 0) {
        return float_failure_process(expected, FloatFailureKind.COMPILE, compiled, mutation);
    }
    ProcessResult runtime = run_program({ executable }) ?? unreachable();
    FloatFailure failure = float_failure_process(expected, FloatFailureKind.NONE,
        runtime, mutation);
    bool mismatch = runtime.status != expected.status ||
        failure.actual_output.str_view() != failure.expected_output.str_view() ||
        failure.actual_errors.str_view() != failure.expected_errors.str_view();
    if (mismatch) failure.kind = FloatFailureKind.RUNTIME;
    if (float_collect && mutation == 0 && failure.kind == FloatFailureKind.NONE) {
        if (item.failure == 0) {
            float_cover_valid(item);
        } else {
            float_direct_attribution = float_direct_current;
            float_cover_fault(item);
            float_direct_attribution = false;
        }
    }
    if (mismatch && mutation == 0) {
        io::eprintfn("float mismatch width=%d form=%d fault=%d", (int)item.width,
            item.form, item.failure);
        print_result(runtime);
    }
    return failure;
}

fn bool float_failure_same(FloatCase candidate, FloatFailure original) {
    FloatFailure current = float_execute(candidate, original.mutation);
    return current.kind == original.kind && current.expected_status == original.expected_status &&
        current.actual_status == original.actual_status &&
        current.expected_output.str_view() == original.expected_output.str_view() &&
        current.expected_errors.str_view() == original.expected_errors.str_view() &&
        current.actual_output.str_view() == original.actual_output.str_view() &&
        current.actual_errors.str_view() == original.actual_errors.str_view();
}

fn FloatCase float_mutation_case(FloatWidth width, int mutation) {
    FloatCase item = {};
    switch (mutation) {
        case 1: item = float_valid_case(width, 34); break;
        case 2:
            item = float_valid_case(width, width == FloatWidth.F32 ? 27 : 27);
            item.left = 0x8000000000000000;
            break;
        case 3:
            item = float_valid_case(width, 7);
            item.left = width == FloatWidth.F32 ? 0x7fc00000 : 0x7ff8000000000000;
            item.right = 0;
            item.immediate = false;
            break;
        case 4: item = float_fault_case(width, 0); break;
        case 5:
            item = float_valid_case(width, 5);
            item.fma_probe = true;
            item.immediate = false;
            item.left = width == FloatWidth.F32 ? 0x3f800400 : 0x3ff0000001000000;
            item.right = width == FloatWidth.F32 ? 0x3f7ff800 : 0x3feffffffe000000;
            break;
        default: unreachable();
    }
    item.padding = mutation == 5 ? 1 : 2;
    return item;
}

fn int float_oracle_main(FloatWidth width) {
    defer (void)cleanup_temp_dir();
    reset_temp_dir() ?? unreachable();
    float_reference_selftest();
    float_coverage_reset();
    float_attempt = 0;
    float_collect = true;
    for (int i = 0; i < 64; i++) {
        FloatCase item = float_valid_case(width, i);
        FloatFailure result = float_execute(item, 0);
        if (!expect(float_clean_ok(item, result), "valid float corpus")) return 1;
    }
    for (int i = 0; i < 64; i++) {
        float_direct_current = i < 16;
        FloatCase item = float_fault_case(width, i);
        FloatFailure result = float_execute(item, 0);
        if (!expect(float_clean_ok(item, result), "fault float corpus")) return 1;
    }
    float_direct_current = false;
    float_collect = false;
    if (!float_coverage_ok(width)) return 1;
    FloatFailure clean = float_execute(float_valid_case(width, 0), 0);
    if (!expect(clean.kind == FloatFailureKind.NONE, "clean mutation control")) return 1;
    FloatFailure[5] originals;
    for (int mutation = 1; mutation <= 5; mutation++) {
        FloatCase item = float_mutation_case(width, mutation);
        originals[mutation - 1] = float_execute(item, mutation);
        if (originals[mutation - 1].kind != FloatFailureKind.RUNTIME) {
            io::eprintfn("mutation=%d kind=%d expected=%d/%s actual=%d/%s", mutation,
                (int)originals[mutation - 1].kind, originals[mutation - 1].expected_status,
                originals[mutation - 1].expected_output.str_view(),
                originals[mutation - 1].actual_status,
                originals[mutation - 1].actual_output.str_view());
            io::eprintn(float_case_source(item));
            return 1;
        }
    }
    for (int mutation = 1; mutation <= 5; mutation++) {
        FloatCase original = float_mutation_case(width, mutation);
        while (original.padding > 0) {
            original.padding--;
            if (!expect(float_failure_same(original, originals[mutation - 1]),
                    "shrink preserves complete mismatch signature")) return 1;
        }
    }
    for (int i = 0; i < 6; i++) {
        FloatCase same = float_mutation_case(width, i % 5 + 1);
        same.padding = 0;
        if (!expect(float_failure_same(same, originals[i % 5]),
                "mismatch signature positive")) return 1;
    }
    for (int i = 0; i < 6; i++) {
        FloatCase different = float_mutation_case(width, 4);
        different.prefix = i + 1;
        different.failure_line += different.prefix;
        if (!expect(!float_failure_same(different, originals[3]),
                "mismatch signature rejects different fault line")) return 1;
    }
    io::printfn("FLOAT_COVERAGE valid=%d fault=%d direct_invalid=%d direct_memory=%d",
        float_coverage.valid, float_coverage.faults, float_coverage.direct_invalid,
        float_coverage.direct_memory);
    return 0;
}


fn String float_concat(String left, String right) {
    DString result = dstring::temp(left);
    result.append_string(right);
    return result.str_view();
}


fn bool float_clean_ok(FloatCase item, FloatFailure result) {
    if (result.kind == FloatFailureKind.NONE) return true;
    io::eprintfn("float clean failure kind=%d form=%d fault=%d", (int)result.kind,
        item.form, item.failure);
    io::eprintn(float_case_source(item));
    io::eprintfn("expected status=%d out=%s err=%s", result.expected_status,
        result.expected_output.str_view(), result.expected_errors.str_view());
    io::eprintfn("actual status=%d out=%s err=%s", result.actual_status,
        result.actual_output.str_view(), result.actual_errors.str_view());
    return false;
}
