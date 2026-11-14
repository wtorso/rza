/* RZA cell mediators and defined i64 arithmetic. C23. */
#ifndef REZ3EXT_H
#define REZ3EXT_H

#include "rez3.h"

#define REZ3EXT_ABI 4u
static_assert(REZ3EXT_ABI == 4);

#define REZ_ASYNC_MAX 64u

typedef bool (*RezAsyncRun)(void *context);

typedef struct {
    RezAsyncRun run;
    void *context;
} RezAsyncTask;

typedef struct {
    RezAsyncTask tasks[REZ_ASYNC_MAX];
    uint32_t head;
    uint32_t count;
} RezAsyncQueue;

[[maybe_unused]] static bool rez_async_enqueue(
    RezAsyncQueue *queue,
    RezAsyncRun run,
    void *context,
    bool *pending
) {
    uint32_t index;
    assert(queue != nullptr);
    assert(run != nullptr);
    assert(context != nullptr);
    assert(pending != nullptr);
    assert(queue->count <= REZ_ASYNC_MAX);
    if (*pending || queue->count == REZ_ASYNC_MAX) return false;
    index = (queue->head + queue->count) % REZ_ASYNC_MAX;
    queue->tasks[index] = (RezAsyncTask){ .run = run, .context = context };
    queue->count++;
    *pending = true;
    return true;
}

[[maybe_unused]] static uint64_t rez_async_drain(RezAsyncQueue *queue) {
    uint64_t completed = 0;
    assert(queue != nullptr);
    assert(queue->count <= REZ_ASYNC_MAX);
    while (queue->count > 0) {
        RezAsyncTask task = queue->tasks[queue->head];
        bool success;
        assert(task.run != nullptr);
        assert(task.context != nullptr);
        queue->tasks[queue->head] = (RezAsyncTask){0};
        queue->head = (queue->head + 1) % REZ_ASYNC_MAX;
        queue->count--;
        success = task.run(task.context);
        if (success) completed++;
    }
    queue->head = 0;
    return completed;
}

typedef struct {
    void *cell;
    RezCavity *owner;
    RezCavity *home;
    uint32_t gen;
    uint32_t home_gen;
    uint64_t size;
} RezCellMed;

static_assert(sizeof(((RezCellMed *)nullptr)->gen) == 4);
static_assert(sizeof(((RezCellMed *)nullptr)->size) == 8);

[[maybe_unused]] static RezCellMed rez_issue_cell(
    RezCavity *owner,
    RezCavity *home,
    void *cell,
    uint64_t size
) {
    RezCellMed mediator;
    assert(owner != nullptr);
    assert(home != nullptr);
    mediator.cell = cell;
    mediator.owner = owner;
    mediator.home = home;
    mediator.gen = owner->generation;
    mediator.home_gen = home->generation;
    mediator.size = size;
    assert(mediator.gen == owner->generation);
    assert(mediator.home_gen == home->generation);
    return mediator;
}

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void *rez_deref_cell_inline(RezCellMed mediator) {
    if (mediator.cell == nullptr) return nullptr;
    if (mediator.owner == nullptr) return nullptr;
    if (mediator.home == nullptr) return nullptr;
    if (!mediator.owner->alive) return nullptr;
    if (!mediator.home->alive) return nullptr;
    if (mediator.gen != mediator.owner->generation) return nullptr;
    if (mediator.home_gen != mediator.home->generation) return nullptr;
    assert(mediator.gen != 0);
    assert(mediator.home_gen != 0);
    return mediator.cell;
}

[[maybe_unused]] static void *rez_deref_cell(RezCellMed mediator) {
    return rez_deref_cell_inline(mediator);
}

[[maybe_unused]] static bool rez_cell_bounds(
    RezCellMed mediator,
    uint64_t offset,
    uint64_t width
) {
    assert(mediator.size <= UINT64_MAX);
    if (offset > mediator.size) return false;
    assert(offset <= mediator.size);
    return width <= mediator.size - offset;
}

[[maybe_unused]] static uint64_t rez_i64_bits(int64_t value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    assert(sizeof(bits) == sizeof(value));
    return bits;
}

[[maybe_unused]] static int64_t rez_i64_value(uint64_t bits) {
    int64_t value;
    memcpy(&value, &bits, sizeof(value));
    assert(sizeof(value) == sizeof(bits));
    return value;
}

[[maybe_unused]] static int64_t rez_i64_add(int64_t left, int64_t right) {
    return rez_i64_value(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i64_sub(int64_t left, int64_t right) {
    return rez_i64_value(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i64_mul(int64_t left, int64_t right) {
    return rez_i64_value(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static bool rez_i64_cadd(
    int64_t left,
    int64_t right,
    int64_t *result
) {
    assert(result != nullptr);
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_add_overflow(left, right, result);
#else
    if (right > 0 && left > INT64_MAX - right) return true;
    if (right < 0 && left < INT64_MIN - right) return true;
    *result = rez_i64_add(left, right);
    return false;
#endif
}

[[maybe_unused]] static bool rez_i64_csub(
    int64_t left,
    int64_t right,
    int64_t *result
) {
    assert(result != nullptr);
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_sub_overflow(left, right, result);
#else
    if (right > 0 && left < INT64_MIN + right) return true;
    if (right < 0 && left > INT64_MAX + right) return true;
    *result = rez_i64_sub(left, right);
    return false;
#endif
}

[[maybe_unused]] static bool rez_i64_cmul(
    int64_t left,
    int64_t right,
    int64_t *result
) {
    assert(result != nullptr);
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_mul_overflow(left, right, result);
#else
    int64_t wrapped;
    if (left == 0 || right == 0) {
        *result = 0;
        return false;
    }
    if (left == -1 && right == INT64_MIN) return true;
    if (left == INT64_MIN && right == -1) return true;
    wrapped = rez_i64_mul(left, right);
    if (wrapped / right != left) return true;
    *result = wrapped;
    return false;
#endif
}

[[maybe_unused]] static int64_t rez_i64_div(int64_t left, int64_t right) {
    assert(right != 0);
    if (left == INT64_MIN) assert(right != -1);
    return left / right;
}

[[maybe_unused]] static int64_t rez_i64_mod(int64_t left, int64_t right) {
    assert(right != 0);
    if (left == INT64_MIN) assert(right != -1);
    return left % right;
}

[[maybe_unused]] static int64_t rez_i64_shl(int64_t value, int64_t shift) {
    assert(shift >= 0);
    assert(shift < 64);
    return rez_i64_value(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i64_shr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(shift >= 0);
    assert(shift < 64);
    if (shift == 0) return value;
    bits = rez_i64_bits(value) >> (unsigned)shift;
    if (value < 0) bits |= ~(uint64_t)0 << (64 - (unsigned)shift);
    return rez_i64_value(bits);
}

[[maybe_unused]] static int64_t rez_i64_ushr(int64_t value, int64_t shift) {
    assert(shift >= 0);
    assert(shift < 64);
    return rez_i64_value(rez_i64_bits(value) >> (unsigned)shift);
}

#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
#include <cpuid.h>
#include <smmintrin.h>
#define REZ_CRC32C_X86 1
#else
#define REZ_CRC32C_X86 0
#endif

#if REZ_CRC32C_X86
static int rez_crc32c_hw = -1;
__attribute__((target("sse4.2")))
static uint64_t rez_crc32c_u64_x86(uint64_t state, uint64_t word) {
    return (uint64_t)_mm_crc32_u64((unsigned int)state, (long long)word);
}
#endif

[[maybe_unused]] static bool rez_crc32c_hardware(void) {
#if REZ_CRC32C_X86
    if (rez_crc32c_hw < 0) {
        unsigned int eax, ebx, ecx, edx;
        __cpuid(1, eax, ebx, ecx, edx);
        rez_crc32c_hw = (ecx & (1U << 19)) != 0;
    }
    return rez_crc32c_hw != 0;
#else
    return false;
#endif
}

[[maybe_unused]] static uint64_t rez_crc32c_u64_fallback(uint64_t state, uint64_t word) {
    uint32_t crc = (uint32_t)state;
    for (unsigned int byte = 0; byte < 8; byte++) {
        crc ^= (word >> (byte * 8)) & 255U;
        for (unsigned int bit = 0; bit < 8; bit++) {
            uint32_t low = crc & 1U;
            crc >>= 1;
            if (low != 0) crc ^= UINT32_C(0x82f63b78);
        }
    }
    return (uint64_t)crc;
}

[[maybe_unused]] static uint64_t rez_crc32c_u64(uint64_t state, uint64_t word) {
#if REZ_CRC32C_X86
    if (rez_crc32c_hardware()) return rez_crc32c_u64_x86(state, word);
#endif
    return rez_crc32c_u64_fallback(state, word);
}

#define REZ_TRY(expr) do { if (!(expr)) return -1; } while (0)

#endif
