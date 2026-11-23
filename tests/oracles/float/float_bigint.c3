module rza_tests;

const int BIGINT_LIMBS = 80;
const int BIGINT_BITS = BIGINT_LIMBS * 32;
const int FLOAT_MAX_ALIGNMENT_SHIFT = 2097;
const int FLOAT_MAX_ALIGNED_BITS = 2150;

struct BigInt {
    uint[BIGINT_LIMBS] limbs;
    int used;
}

fn void bigint_normalize(BigInt* value) {
    while (value.used > 0 && value.limbs[value.used - 1] == 0) value.used--;
}

fn BigInt bigint_from_u64(ulong input) {
    BigInt value = {};
    if (input == 0) return value;
    value.limbs[0] = (uint)input;
    value.limbs[1] = (uint)(input >> 32);
    value.used = value.limbs[1] == 0 ? 1 : 2;
    return value;
}

fn ulong bigint_low_u64(BigInt value) {
    assert(value.used <= 2);
    ulong high = value.used == 2 ? (ulong)value.limbs[1] : 0;
    return value.limbs[0] | high << 32;
}

fn int bigint_bit_length(BigInt value) {
    if (value.used == 0) return 0;
    uint high = value.limbs[value.used - 1];
    int bits = 0;
    while (high != 0) {
        bits++;
        high >>= 1;
    }
    return (value.used - 1) * 32 + bits;
}

fn int bigint_compare(BigInt left, BigInt right) {
    if (left.used != right.used) return left.used < right.used ? -1 : 1;
    for (int i = left.used - 1; i >= 0; i--) {
        if (left.limbs[i] != right.limbs[i]) {
            return left.limbs[i] < right.limbs[i] ? -1 : 1;
        }
    }
    return 0;
}

fn BigInt bigint_add(BigInt left, BigInt right) {
    BigInt result = {};
    ulong carry = 0;
    int count = left.used > right.used ? left.used : right.used;
    assert(count < BIGINT_LIMBS || carry == 0);
    for (int i = 0; i < count; i++) {
        ulong sum = carry;
        if (i < left.used) sum += left.limbs[i];
        if (i < right.used) sum += right.limbs[i];
        result.limbs[i] = (uint)sum;
        carry = sum >> 32;
    }
    result.used = count;
    if (carry != 0) {
        assert(result.used < BIGINT_LIMBS);
        result.limbs[result.used] = (uint)carry;
        result.used++;
    }
    return result;
}

fn BigInt bigint_sub(BigInt left, BigInt right) {
    assert(bigint_compare(left, right) >= 0);
    BigInt result = {};
    long borrow = 0;
    for (int i = 0; i < left.used; i++) {
        long difference = (long)left.limbs[i] - borrow;
        if (i < right.used) difference -= right.limbs[i];
        if (difference < 0) {
            difference += (long)1 << 32;
            borrow = 1;
        } else {
            borrow = 0;
        }
        result.limbs[i] = (uint)difference;
    }
    assert(borrow == 0);
    result.used = left.used;
    bigint_normalize(&result);
    return result;
}

fn BigInt bigint_mul(BigInt left, BigInt right) {
    BigInt result = {};
    if (left.used == 0 || right.used == 0) return result;
    assert(left.used + right.used <= BIGINT_LIMBS);
    result.used = left.used + right.used;
    for (int i = 0; i < left.used; i++) {
        ulong carry = 0;
        for (int j = 0; j < right.used; j++) {
            int index = i + j;
            ulong product = (ulong)left.limbs[i] * right.limbs[j];
            ulong sum = product + result.limbs[index] + carry;
            result.limbs[index] = (uint)sum;
            carry = sum >> 32;
        }
        int index = i + right.used;
        assert(index < BIGINT_LIMBS);
        ulong sum = (ulong)result.limbs[index] + carry;
        result.limbs[index] = (uint)sum;
        carry = sum >> 32;
        assert(carry == 0);
    }
    bigint_normalize(&result);
    return result;
}

fn bool bigint_set_bit(BigInt* value, int index) {
    if (index < 0 || index >= BIGINT_BITS) return false;
    int limb = index / 32;
    value.limbs[limb] |= (uint)1 << (index % 32);
    if (value.used <= limb) value.used = limb + 1;
    return true;
}

fn uint bigint_bit(BigInt value, int index) {
    if (index < 0 || index >= BIGINT_BITS) return 0;
    return (value.limbs[index / 32] >> (index % 32)) & 1;
}

fn bool bigint_shift_left(BigInt* value, uint amount) {
    if (value.used == 0 || amount == 0) return true;
    if (amount >= BIGINT_BITS || bigint_bit_length(*value) + (int)amount > BIGINT_BITS) {
        return false;
    }
    BigInt result = {};
    uint words = amount / 32;
    uint bits = amount % 32;
    for (int i = value.used - 1; i >= 0; i--) {
        int index = i + (int)words;
        ulong shifted = (ulong)value.limbs[i] << bits;
        result.limbs[index] |= (uint)shifted;
        if (bits != 0 && index + 1 < BIGINT_LIMBS) {
            result.limbs[index + 1] |= (uint)(shifted >> 32);
        } else if (bits != 0) {
            assert((uint)(shifted >> 32) == 0);
        }
    }
    result.used = value.used + (int)words;
    if (bits != 0 && result.used < BIGINT_LIMBS) result.used++;
    bigint_normalize(&result);
    *value = result;
    return true;
}

fn void bigint_shift_right(BigInt* value, uint amount) {
    if (value.used == 0 || amount == 0) return;
    if (amount >= BIGINT_BITS) {
        *value = {};
        return;
    }
    BigInt result = {};
    uint words = amount / 32;
    uint bits = amount % 32;
    for (int i = 0; i < value.used - (int)words; i++) {
        int source = i + (int)words;
        ulong shifted = (ulong)value.limbs[source] >> bits;
        if (bits != 0 && source + 1 < value.used) {
            shifted |= (ulong)value.limbs[source + 1] << (32 - bits);
        }
        result.limbs[i] = (uint)shifted;
    }
    result.used = value.used - (int)words;
    bigint_normalize(&result);
    *value = result;
}

fn void bigint_divmod(BigInt numerator, BigInt denominator,
        BigInt* quotient, BigInt* remainder) {
    assert(denominator.used != 0 && quotient != null && remainder != null);
    *quotient = {};
    *remainder = {};
    int bits = bigint_bit_length(numerator);
    for (int index = bits - 1; index >= 0; index--) {
        assert(bigint_shift_left(remainder, 1));
        if (bigint_bit(numerator, index) != 0) {
            remainder.limbs[0] |= 1;
            if (remainder.used == 0) remainder.used = 1;
        }
        if (bigint_compare(*remainder, denominator) >= 0) {
            *remainder = bigint_sub(*remainder, denominator);
            assert(bigint_set_bit(quotient, index));
        }
    }
}
