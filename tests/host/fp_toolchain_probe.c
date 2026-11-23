#define _GNU_SOURCE

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "rez3ext.h"

#if !defined(FP_PROBE_NEGATIVE)
#ifndef FP_PROBE_ALLOW_CONTRACTION
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#pragma clang fp reassociate(off)
#elif defined(__GNUC__)
#pragma GCC optimize ("fp-contract=off")
#endif
#endif

#if defined(_MSC_VER)
#pragma float_control(precise, on)
#pragma float_control(except, off)
#pragma fenv_access(off)
#pragma fp_contract(off)
#endif
#endif

#if (defined(__FAST_MATH__) && __FAST_MATH__ != 0) || \
    (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__ != 0)
#error "fast-math or finite-only mode is enabled"
#endif

_Static_assert(CHAR_BIT == 8, "eight-bit bytes required");
_Static_assert(sizeof(float) == 4, "binary32 size required");
_Static_assert(sizeof(double) == 8, "binary64 size required");
_Static_assert(FLT_RADIX == 2, "binary radix required");
_Static_assert(FLT_MANT_DIG == 24, "binary32 mantissa required");
_Static_assert(DBL_MANT_DIG == 53, "binary64 mantissa required");
_Static_assert(FLT_MIN_EXP == -125, "binary32 minimum exponent required");
_Static_assert(FLT_MAX_EXP == 128, "binary32 maximum exponent required");
_Static_assert(DBL_MIN_EXP == -1021, "binary64 minimum exponent required");
_Static_assert(DBL_MAX_EXP == 1024, "binary64 maximum exponent required");
#if FLT_EVAL_METHOD != 0
#error "floating evaluation must round at the declared type"
#endif
#if defined(__STDC_IEC_559__) && __STDC_IEC_559__ != 1
#error "IEC 60559 declarations are inconsistent"
#endif

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

static volatile double source_a = 1.0 + 0x1p-52;
static volatile double source_b = 1.0 - 0x1p-52;
static volatile double source_half = 1.0 + 0x1p-24;
static volatile double source_next = 1.0 + 0x1p-23 + 0x1p-25;
static volatile double source_max = DBL_MAX;
static volatile double source_zero = 0.0;
static volatile uint64_t source_tie32_low = UINT64_C(16777217);
static volatile uint64_t source_tie32_high = UINT64_C(16777219);
static volatile uint64_t source_tie64_low = UINT64_C(9007199254740993);
static volatile uint64_t source_tie64_high = UINT64_C(9007199254740995);

#if defined(_MSC_VER)
#define FP_NOINLINE __declspec(noinline)
#else
#define FP_NOINLINE __attribute__((noinline))
#endif

static FP_NOINLINE double mul_add(double a, double b, double c) {
    uint64_t left;
    uint64_t right;
    uint64_t addend;
    memcpy(&left, &a, sizeof(left));
    memcpy(&right, &b, sizeof(right));
    memcpy(&addend, &c, sizeof(addend));
    int64_t product = rez_f64_mul((int64_t)left, (int64_t)right);
    return rez_f64_value(rez_f64_add(product, (int64_t)addend));
}

static FP_NOINLINE float narrow(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return rez_f32_value(rez_f32_from_f64((int64_t)bits));
}

static FP_NOINLINE float from_u32(uint32_t value) {
    return rez_f32_value(rez_f32_from_u64((int64_t)(uint64_t)value));
}

static FP_NOINLINE float from_f32_u64(uint64_t value) {
    return rez_f32_value(rez_f32_from_u64(rez_i64_value(value)));
}

static FP_NOINLINE float from_f32_i64(int64_t value) {
    return rez_f32_value(rez_f32_from_i64(value));
}

static FP_NOINLINE double from_f64_u64(uint64_t value) {
    return rez_f64_value(rez_f64_from_u64(rez_i64_value(value)));
}

static FP_NOINLINE double from_f64_i64(int64_t value) {
    return rez_f64_value(rez_f64_from_i64(value));
}

static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

int main(void) {
    CHECK(narrow(source_half) == 1.0f);
    CHECK(float_bits(narrow(source_next)) == 0x3f800001U);
    CHECK(from_u32(16777217U) == 16777216.0f);
    CHECK(from_u32(16777219U) == 16777220.0f);
    CHECK(float_bits(from_f32_u64(source_tie32_low)) == 0x4b800000U);
    CHECK(float_bits(from_f32_u64(source_tie32_high)) == 0x4b800002U);
    CHECK(float_bits(from_f32_i64((int64_t)source_tie32_low)) == 0x4b800000U);
    CHECK(float_bits(from_f32_i64((int64_t)source_tie32_high)) == 0x4b800002U);
    CHECK(double_bits(from_f64_u64(source_tie64_low)) == UINT64_C(0x4340000000000000));
    CHECK(double_bits(from_f64_u64(source_tie64_high)) == UINT64_C(0x4340000000000002));
    CHECK(double_bits(from_f64_i64((int64_t)source_tie64_low)) ==
        UINT64_C(0x4340000000000000));
    CHECK(double_bits(from_f64_i64((int64_t)source_tie64_high)) ==
        UINT64_C(0x4340000000000002));
    CHECK(from_f32_u64(UINT64_MAX) == 0x1p64);
    CHECK(from_f64_i64(INT64_MAX) == 0x1p63);

    CHECK(narrow(0x1p-150) == 0.0f);
    CHECK(narrow(0x1p-149) == 0x1p-149f);
    CHECK(narrow(0x1p-149 + 0x1p-150) == 0x1p-148f);
    CHECK(source_max * 2.0 == INFINITY);

    CHECK(source_zero == 0.0);
    CHECK(signbit(-source_zero));
    CHECK(1.0 / source_zero == INFINITY);
    CHECK(1.0 / -source_zero == -INFINITY);
    CHECK(isnan(source_zero / source_zero));
    CHECK(source_zero / source_zero != source_zero / source_zero);

    CHECK(rez_f32_add(0x3f800000, 0x33800000) == 0x3f800000);
    CHECK(rez_f32_add(0x7f7fffff, 0x7f7fffff) == 0x7f800000);
    CHECK(rez_f32_add(1, 1) == 2);
    CHECK(rez_f32_div(0x3f800000, 0) == 0x7f800000);
    CHECK(rez_f32_feq(0x80000000, 0) == 1);
    CHECK(rez_f32_fne(0x7fc00000, 0x3f800000) == 1);
    double maximum = source_max;
    uint64_t max_bits;
    memcpy(&max_bits, &maximum, sizeof(max_bits));
    int64_t two = rez_f64_from_bits(UINT64_C(0x4000000000000000));
    CHECK(rez_f64_mul((int64_t)max_bits, two) == 0x7ff0000000000000);
    CHECK(rez_f64_add(1, 1) == 2);
    CHECK(rez_f64_div(rez_f64_from_bits(0x3ff0000000000000), 0) ==
        0x7ff0000000000000);
    CHECK(rez_f64_flt(rez_f64_from_bits(0x7ff8000000000000), 0) == 0);

    CHECK(mul_add(source_a, source_b, -1.0) == 0.0);
    puts("FP_TOOLCHAIN_PROBE OK");
    return 0;
}
