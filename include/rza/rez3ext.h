/* RZA cell mediators and defined i64 arithmetic. C23. */
#ifndef REZ3EXT_H
#define REZ3EXT_H

#include "rez3.h"

#define REZ3EXT_ABI 5u
static_assert(REZ3EXT_ABI == 5);

typedef enum {
    RZA_OK = 0,
    RZA_ABORT = 1,
    RZA_FAULT_DEAD_MEDIATOR = 2,
    RZA_FAULT_ARITHMETIC_OVERFLOW = 3,
    RZA_FAULT_OUT_OF_BOUNDS = 4,
    RZA_FAULT_DIVISION = 5,
    RZA_FAULT_SHIFT = 6,
    RZA_FAULT_FRAME = 7,
    RZA_FAULT_ARENA = 8,
    RZA_FAULT_ASYNC_PENDING = 9,
    RZA_FAULT_ASYNC_QUEUE = 10,
    RZA_FAULT_VIEW = 11,
    RZA_FAULT_ENTRY_STATE = 12
} RzaFault;

typedef struct {
    uint32_t code;
    uint32_t line;
} RzaResult;

typedef struct {
    uint64_t completed;
    RzaResult result;
} RzaAwaitResult;

typedef struct {
    uint32_t fault;
    uint32_t line;
    const char *operation;
    const char *subject;
} RzaDiagnostic;

typedef void (*RzaDiagnosticHandler)(RzaDiagnostic diagnostic, void *context);

static_assert(sizeof(RzaResult) == 8);
static_assert(sizeof(RzaAwaitResult) == 16);

#define REZ_ASYNC_MAX 64u

typedef RzaResult (*RezAsyncRun)(void *context);

typedef struct {
    RezAsyncRun run;
    void *context;
} RezAsyncTask;

typedef struct {
    RezAsyncTask tasks[REZ_ASYNC_MAX];
    uint32_t head;
    uint32_t count;
} RezAsyncQueue;

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void rez_async_regs_clear(int64_t *regs) {
    assert(regs != nullptr);
    regs[0] = 0;
    regs[1] = 0;
    regs[2] = 0;
    regs[3] = 0;
    regs[4] = 0;
    regs[5] = 0;
    regs[6] = 0;
    regs[7] = 0;
    regs[8] = 0;
    regs[9] = 0;
    regs[10] = 0;
    regs[11] = 0;
    regs[12] = 0;
    regs[13] = 0;
    regs[14] = 0;
    regs[15] = 0;
}

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

[[maybe_unused]] static void rez_async_cancel(RezAsyncQueue *queue) {
    assert(queue != nullptr);
    assert(queue->count <= REZ_ASYNC_MAX);
    memset(queue->tasks, 0, sizeof(queue->tasks));
    queue->head = 0;
    queue->count = 0;
}

[[maybe_unused]] static RzaAwaitResult rez_async_drain(RezAsyncQueue *queue) {
    RzaAwaitResult drained = {0};
    assert(queue != nullptr);
    assert(queue->count <= REZ_ASYNC_MAX);
    while (queue->count > 0) {
        RezAsyncTask task = queue->tasks[queue->head];
        RzaResult status;
        assert(task.run != nullptr);
        assert(task.context != nullptr);
        queue->tasks[queue->head] = (RezAsyncTask){0};
        queue->head = (queue->head + 1) % REZ_ASYNC_MAX;
        queue->count--;
        status = task.run(task.context);
        if (status.code == RZA_OK) drained.completed++;
        if (status.code != RZA_OK && status.code != RZA_ABORT) {
            drained.result = status;
            rez_async_cancel(queue);
            return drained;
        }
    }
    queue->head = 0;
    return drained;
}

typedef struct {
    void *cell;
    RezCavity *owner;
    RezCavity *home;
    uint32_t gen;
    uint32_t home_gen;
    uint64_t size;
    uint32_t *allocation;
    uint32_t allocation_gen;
} RezCellMed;

static_assert(sizeof(((RezCellMed *)nullptr)->gen) == 4);
static_assert(sizeof(((RezCellMed *)nullptr)->size) == 8);
static_assert(sizeof(RezCellMed) == 56);

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void rez_cell_med_clear(RezCellMed *mediator) {
    assert(mediator != nullptr);
    mediator->cell = nullptr;
    mediator->owner = nullptr;
    mediator->home = nullptr;
    mediator->gen = 0;
    mediator->home_gen = 0;
    mediator->size = 0;
    mediator->allocation = nullptr;
    mediator->allocation_gen = 0;
}

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void rez_cell_med_copy(RezCellMed *destination, const RezCellMed *source) {
    assert(destination != nullptr);
    assert(source != nullptr);
    destination->cell = source->cell;
    destination->owner = source->owner;
    destination->home = source->home;
    destination->gen = source->gen;
    destination->home_gen = source->home_gen;
    destination->size = source->size;
    destination->allocation = source->allocation;
    destination->allocation_gen = source->allocation_gen;
}

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
    mediator.allocation = nullptr;
    mediator.allocation_gen = 0;
    assert(mediator.gen == owner->generation);
    assert(mediator.home_gen == home->generation);
    return mediator;
}

[[maybe_unused]] static RezCellMed rez_issue_cell_versioned(
    RezCavity *owner,
    RezCavity *home,
    void *cell,
    uint64_t size,
    uint32_t *allocation
) {
    assert(allocation != nullptr);
    assert(*allocation != 0);
    RezCellMed mediator = rez_issue_cell(owner, home, cell, size);
    mediator.allocation = allocation;
    mediator.allocation_gen = *allocation;
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
    if (mediator.allocation != nullptr) {
        if (mediator.allocation_gen == 0) return nullptr;
        if (mediator.allocation_gen != *mediator.allocation) return nullptr;
    }
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

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
bool rez_view_cell(
    RezCellMed source,
    uint64_t offset,
    uint64_t length,
    uint64_t stride,
    RezCellMed *out
) {
    uint64_t elements;
    uint64_t byte_offset;
    if (out == nullptr) return false;
    rez_cell_med_clear(out);
    if (stride == 0) return false;
    if (rez_deref_cell_inline(source) == nullptr) return false;
    if (source.size % stride != 0) return false;
    elements = source.size / stride;
    if (offset > elements) return false;
    if (length > elements - offset) return false;
    byte_offset = offset * stride;
    source.cell = (char *)source.cell + byte_offset;
    source.size = length * stride;
    rez_cell_med_copy(out, &source);
    assert(out->size <= elements * stride);
    return true;
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
