/* RZA cell mediators and defined integer arithmetic. C23. */
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
    assert(regs != NULL);
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
    assert(queue != NULL);
    assert(run != NULL);
    assert(context != NULL);
    assert(pending != NULL);
    assert(queue->count <= REZ_ASYNC_MAX);
    if (*pending || queue->count == REZ_ASYNC_MAX) return false;
    index = (queue->head + queue->count) % REZ_ASYNC_MAX;
    queue->tasks[index] = (RezAsyncTask){ .run = run, .context = context };
    queue->count++;
    *pending = true;
    return true;
}

[[maybe_unused]] static void rez_async_cancel(RezAsyncQueue *queue) {
    assert(queue != NULL);
    assert(queue->count <= REZ_ASYNC_MAX);
    memset(queue->tasks, 0, sizeof(queue->tasks));
    queue->head = 0;
    queue->count = 0;
}

[[maybe_unused]] static RzaAwaitResult rez_async_drain(RezAsyncQueue *queue) {
    RzaAwaitResult drained = {0};
    assert(queue != NULL);
    assert(queue->count <= REZ_ASYNC_MAX);
    while (queue->count > 0) {
        RezAsyncTask task = queue->tasks[queue->head];
        RzaResult status;
        assert(task.run != NULL);
        assert(task.context != NULL);
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

static_assert(sizeof(((RezCellMed *)NULL)->gen) == 4);
static_assert(sizeof(((RezCellMed *)NULL)->size) == 8);
static_assert(sizeof(RezCellMed) == 56);

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void rez_cell_med_clear(RezCellMed *mediator) {
    assert(mediator != NULL);
    mediator->cell = NULL;
    mediator->owner = NULL;
    mediator->home = NULL;
    mediator->gen = 0;
    mediator->home_gen = 0;
    mediator->size = 0;
    mediator->allocation = NULL;
    mediator->allocation_gen = 0;
}

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void rez_cell_med_copy(RezCellMed *destination, const RezCellMed *source) {
    assert(destination != NULL);
    assert(source != NULL);
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
    assert(owner != NULL);
    assert(home != NULL);
    mediator.cell = cell;
    mediator.owner = owner;
    mediator.home = home;
    mediator.gen = owner->generation;
    mediator.home_gen = home->generation;
    mediator.size = size;
    mediator.allocation = NULL;
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
    assert(allocation != NULL);
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
bool rez_cell_med_metadata_ok(RezCellMed mediator) {
    if (mediator.owner != NULL
            && (uintptr_t)mediator.owner % _Alignof(RezCavity) != 0) return false;
    if (mediator.home != NULL
            && (uintptr_t)mediator.home % _Alignof(RezCavity) != 0) return false;
    if (mediator.allocation != NULL) {
        if ((uintptr_t)mediator.allocation % _Alignof(uint32_t) != 0) return false;
        if (mediator.allocation_gen == 0) return false;
    } else {
        if (mediator.allocation_gen != 0) return false;
    }
    return true;
}

[[maybe_unused]] static inline
#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
void *rez_deref_cell_inline(RezCellMed mediator) {
    if (mediator.cell == NULL) return NULL;
    if (mediator.owner == NULL) return NULL;
    if (mediator.home == NULL) return NULL;
    if (!mediator.owner->alive) return NULL;
    if (!mediator.home->alive) return NULL;
    if (mediator.gen != mediator.owner->generation) return NULL;
    if (mediator.home_gen != mediator.home->generation) return NULL;
    if (mediator.allocation != NULL) {
        if (mediator.allocation_gen == 0) return NULL;
        if (mediator.allocation_gen != *mediator.allocation) return NULL;
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

/* The host guarantees the actual object extent; arbitrary addresses are not validated. */
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
    if (out == NULL) return false;
    rez_cell_med_clear(out);
    if (stride == 0) return false;
    if (!rez_cell_med_metadata_ok(source)) return false;
    if (rez_deref_cell_inline(source) == NULL) return false;
    if (source.size % stride != 0) return false;
    elements = source.size / stride;
    if (offset > elements) return false;
    if (length > elements - offset) return false;
    byte_offset = offset * stride;
    if (byte_offset > UINTPTR_MAX) return false;
    if ((uintptr_t)source.cell > UINTPTR_MAX - byte_offset) return false;
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

[[maybe_unused]] static int64_t rez_u8_from_bits(uint64_t bits) {
    return rez_i64_value(bits & UINT64_C(0xff));
}

[[maybe_unused]] static int64_t rez_i8_from_bits(uint64_t bits) {
    uint64_t low = bits & UINT64_C(0xff);
    if ((low & UINT64_C(0x80)) != 0) low |= ~UINT64_C(0xff);
    return rez_i64_value(low);
}

[[maybe_unused]] static int64_t rez_u16_from_bits(uint64_t bits) {
    return rez_i64_value(bits & UINT64_C(0xffff));
}

[[maybe_unused]] static int64_t rez_i16_from_bits(uint64_t bits) {
    uint64_t low = bits & UINT64_C(0xffff);
    if ((low & UINT64_C(0x8000)) != 0) low |= ~UINT64_C(0xffff);
    return rez_i64_value(low);
}

[[maybe_unused]] static int64_t rez_u32_from_bits(uint64_t bits) {
    return rez_i64_value(bits & UINT64_C(0xffffffff));
}

[[maybe_unused]] static int64_t rez_i32_from_bits(uint64_t bits) {
    uint64_t low = bits & UINT64_C(0xffffffff);
    if ((low & UINT64_C(0x80000000)) != 0) low |= ~UINT64_C(0xffffffff);
    return rez_i64_value(low);
}

[[maybe_unused]] static int64_t rez_i32_add(int64_t left, int64_t right) {
    return rez_i32_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i32_sub(int64_t left, int64_t right) {
    return rez_i32_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i32_mul(int64_t left, int64_t right) {
    return rez_i32_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u32_add(int64_t left, int64_t right) {
    return rez_u32_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u32_sub(int64_t left, int64_t right) {
    return rez_u32_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u32_mul(int64_t left, int64_t right) {
    return rez_u32_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i16_add(int64_t left, int64_t right) {
    return rez_i16_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i16_sub(int64_t left, int64_t right) {
    return rez_i16_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i16_mul(int64_t left, int64_t right) {
    return rez_i16_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u16_add(int64_t left, int64_t right) {
    return rez_u16_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u16_sub(int64_t left, int64_t right) {
    return rez_u16_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u16_mul(int64_t left, int64_t right) {
    return rez_u16_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i8_add(int64_t left, int64_t right) {
    return rez_i8_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i8_sub(int64_t left, int64_t right) {
    return rez_i8_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_i8_mul(int64_t left, int64_t right) {
    return rez_i8_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u8_add(int64_t left, int64_t right) {
    return rez_u8_from_bits(rez_i64_bits(left) + rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u8_sub(int64_t left, int64_t right) {
    return rez_u8_from_bits(rez_i64_bits(left) - rez_i64_bits(right));
}

[[maybe_unused]] static int64_t rez_u8_mul(int64_t left, int64_t right) {
    return rez_u8_from_bits(rez_i64_bits(left) * rez_i64_bits(right));
}

[[maybe_unused]] static bool rez_i8_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i8_from_bits(rez_i64_bits(left)) +
        rez_i8_from_bits(rez_i64_bits(right));
    if (value < -128 || value > 127) return true;
    *result = rez_i8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i8_csub(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i8_from_bits(rez_i64_bits(left)) -
        rez_i8_from_bits(rez_i64_bits(right));
    if (value < -128 || value > 127) return true;
    *result = rez_i8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i8_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i8_from_bits(rez_i64_bits(left)) *
        rez_i8_from_bits(rez_i64_bits(right));
    if (value < -128 || value > 127) return true;
    *result = rez_i8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u8_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u8_from_bits(rez_i64_bits(left)) +
        rez_u8_from_bits(rez_i64_bits(right));
    if (value > 255) return true;
    *result = rez_u8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u8_csub(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u8_from_bits(rez_i64_bits(left)) -
        rez_u8_from_bits(rez_i64_bits(right));
    if (value < 0) return true;
    *result = rez_u8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u8_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u8_from_bits(rez_i64_bits(left)) *
        rez_u8_from_bits(rez_i64_bits(right));
    if (value > 255) return true;
    *result = rez_u8_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i8_div_invalid(int64_t left, int64_t right) {
    int64_t dividend = rez_i8_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i8_from_bits(rez_i64_bits(right));
    return divisor == 0 || (dividend == -128 && divisor == -1);
}

[[maybe_unused]] static bool rez_u8_div_invalid(int64_t left, int64_t right) {
    (void)left;
    return rez_u8_from_bits(rez_i64_bits(right)) == 0;
}

[[maybe_unused]] static int64_t rez_i8_div(int64_t left, int64_t right) {
    int64_t dividend = rez_i8_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i8_from_bits(rez_i64_bits(right));
    assert(!rez_i8_div_invalid(left, right));
    return rez_i8_from_bits(rez_i64_bits(dividend / divisor));
}

[[maybe_unused]] static int64_t rez_i8_mod(int64_t left, int64_t right) {
    int64_t dividend = rez_i8_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i8_from_bits(rez_i64_bits(right));
    assert(!rez_i8_div_invalid(left, right));
    return rez_i8_from_bits(rez_i64_bits(dividend % divisor));
}

[[maybe_unused]] static int64_t rez_u8_div(int64_t left, int64_t right) {
    int64_t dividend = rez_u8_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_u8_from_bits(rez_i64_bits(right));
    assert(!rez_u8_div_invalid(left, right));
    return rez_u8_from_bits(rez_i64_bits(dividend / divisor));
}

[[maybe_unused]] static int64_t rez_u8_mod(int64_t left, int64_t right) {
    int64_t dividend = rez_u8_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_u8_from_bits(rez_i64_bits(right));
    assert(!rez_u8_div_invalid(left, right));
    return rez_u8_from_bits(rez_i64_bits(dividend % divisor));
}

[[maybe_unused]] static bool rez_shift8_invalid(int64_t shift) {
    return shift < 0 || shift >= 8;
}

[[maybe_unused]] static int64_t rez_i8_shl(int64_t value, int64_t shift) {
    assert(!rez_shift8_invalid(shift));
    return rez_i8_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_u8_shl(int64_t value, int64_t shift) {
    assert(!rez_shift8_invalid(shift));
    return rez_u8_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i8_shr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift8_invalid(shift));
    bits = rez_i64_bits(value) & UINT64_C(0xff);
    if (shift == 0) return rez_i8_from_bits(bits);
    if ((bits & UINT64_C(0x80)) != 0) bits |= ~UINT64_C(0xff);
    return rez_i8_from_bits(bits >> (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i8_ushr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift8_invalid(shift));
    bits = (rez_i64_bits(value) & UINT64_C(0xff)) >> (unsigned)shift;
    return rez_i8_from_bits(bits);
}

[[maybe_unused]] static int64_t rez_u8_ushr(int64_t value, int64_t shift) {
    assert(!rez_shift8_invalid(shift));
    return rez_u8_from_bits((rez_i64_bits(value) & UINT64_C(0xff)) >> (unsigned)shift);
}

[[maybe_unused]] static bool rez_i16_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i16_from_bits(rez_i64_bits(left)) +
        rez_i16_from_bits(rez_i64_bits(right));
    if (value < -32768 || value > 32767) return true;
    *result = rez_i16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i16_csub(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i16_from_bits(rez_i64_bits(left)) -
        rez_i16_from_bits(rez_i64_bits(right));
    if (value < -32768 || value > 32767) return true;
    *result = rez_i16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i16_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i16_from_bits(rez_i64_bits(left)) *
        rez_i16_from_bits(rez_i64_bits(right));
    if (value < -32768 || value > 32767) return true;
    *result = rez_i16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u16_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u16_from_bits(rez_i64_bits(left)) +
        rez_u16_from_bits(rez_i64_bits(right));
    if (value > 65535) return true;
    *result = rez_u16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u16_csub(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u16_from_bits(rez_i64_bits(left)) -
        rez_u16_from_bits(rez_i64_bits(right));
    if (value < 0) return true;
    *result = rez_u16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u16_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_u16_from_bits(rez_i64_bits(left)) *
        rez_u16_from_bits(rez_i64_bits(right));
    if (value > 65535) return true;
    *result = rez_u16_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i16_div_invalid(int64_t left, int64_t right) {
    int64_t dividend = rez_i16_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i16_from_bits(rez_i64_bits(right));
    return divisor == 0 || (dividend == -32768 && divisor == -1);
}

[[maybe_unused]] static bool rez_u16_div_invalid(int64_t left, int64_t right) {
    (void)left;
    return rez_u16_from_bits(rez_i64_bits(right)) == 0;
}

[[maybe_unused]] static int64_t rez_i16_div(int64_t left, int64_t right) {
    int64_t dividend = rez_i16_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i16_from_bits(rez_i64_bits(right));
    assert(!rez_i16_div_invalid(left, right));
    return rez_i16_from_bits(rez_i64_bits(dividend / divisor));
}

[[maybe_unused]] static int64_t rez_i16_mod(int64_t left, int64_t right) {
    int64_t dividend = rez_i16_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i16_from_bits(rez_i64_bits(right));
    assert(!rez_i16_div_invalid(left, right));
    return rez_i16_from_bits(rez_i64_bits(dividend % divisor));
}

[[maybe_unused]] static int64_t rez_u16_div(int64_t left, int64_t right) {
    int64_t dividend = rez_u16_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_u16_from_bits(rez_i64_bits(right));
    assert(!rez_u16_div_invalid(left, right));
    return rez_u16_from_bits(rez_i64_bits(dividend / divisor));
}

[[maybe_unused]] static int64_t rez_u16_mod(int64_t left, int64_t right) {
    int64_t dividend = rez_u16_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_u16_from_bits(rez_i64_bits(right));
    assert(!rez_u16_div_invalid(left, right));
    return rez_u16_from_bits(rez_i64_bits(dividend % divisor));
}

[[maybe_unused]] static bool rez_shift16_invalid(int64_t shift) {
    return shift < 0 || shift >= 16;
}

[[maybe_unused]] static int64_t rez_i16_shl(int64_t value, int64_t shift) {
    assert(!rez_shift16_invalid(shift));
    return rez_i16_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_u16_shl(int64_t value, int64_t shift) {
    assert(!rez_shift16_invalid(shift));
    return rez_u16_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i16_shr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift16_invalid(shift));
    bits = rez_i64_bits(value) & UINT64_C(0xffff);
    if (shift == 0) return rez_i16_from_bits(bits);
    if ((bits & UINT64_C(0x8000)) != 0) bits |= ~UINT64_C(0xffff);
    return rez_i16_from_bits(bits >> (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i16_ushr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift16_invalid(shift));
    bits = (rez_i64_bits(value) & UINT64_C(0xffff)) >> (unsigned)shift;
    return rez_i16_from_bits(bits);
}

[[maybe_unused]] static int64_t rez_u16_ushr(int64_t value, int64_t shift) {
    assert(!rez_shift16_invalid(shift));
    return rez_u16_from_bits((rez_i64_bits(value) & UINT64_C(0xffff)) >>
        (unsigned)shift);
}

[[maybe_unused]] static bool rez_i32_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i32_from_bits(rez_i64_bits(left)) +
        rez_i32_from_bits(rez_i64_bits(right));
    if (value < -2147483648LL || value > 2147483647LL) return true;
    *result = rez_i32_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i32_csub(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i32_from_bits(rez_i64_bits(left)) -
        rez_i32_from_bits(rez_i64_bits(right));
    if (value < -2147483648LL || value > 2147483647LL) return true;
    *result = rez_i32_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_i32_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    int64_t value = rez_i32_from_bits(rez_i64_bits(left)) *
        rez_i32_from_bits(rez_i64_bits(right));
    if (value < -2147483648LL || value > 2147483647LL) return true;
    *result = rez_i32_from_bits(rez_i64_bits(value));
    return false;
}

[[maybe_unused]] static bool rez_u32_cadd(
    int64_t left, int64_t right, int64_t *result
) {
    uint64_t value = (rez_i64_bits(left) & UINT64_C(0xffffffff)) +
        (rez_i64_bits(right) & UINT64_C(0xffffffff));
    if (value > UINT64_C(0xffffffff)) return true;
    *result = rez_u32_from_bits(value);
    return false;
}

[[maybe_unused]] static bool rez_u32_csub(
    int64_t left, int64_t right, int64_t *result
) {
    uint64_t left_bits = rez_i64_bits(left) & UINT64_C(0xffffffff);
    uint64_t right_bits = rez_i64_bits(right) & UINT64_C(0xffffffff);
    if (left_bits < right_bits) return true;
    *result = rez_u32_from_bits(left_bits - right_bits);
    return false;
}

[[maybe_unused]] static bool rez_u32_cmul(
    int64_t left, int64_t right, int64_t *result
) {
    uint64_t value = (rez_i64_bits(left) & UINT64_C(0xffffffff)) *
        (rez_i64_bits(right) & UINT64_C(0xffffffff));
    if (value > UINT64_C(0xffffffff)) return true;
    *result = rez_u32_from_bits(value);
    return false;
}

[[maybe_unused]] static bool rez_i32_div_invalid(int64_t left, int64_t right) {
    int64_t dividend = rez_i32_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i32_from_bits(rez_i64_bits(right));
    return divisor == 0 || (dividend == -2147483648LL && divisor == -1);
}

[[maybe_unused]] static bool rez_u32_div_invalid(int64_t left, int64_t right) {
    (void)left;
    return rez_u32_from_bits(rez_i64_bits(right)) == 0;
}

[[maybe_unused]] static int64_t rez_i32_div(int64_t left, int64_t right) {
    int64_t dividend = rez_i32_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i32_from_bits(rez_i64_bits(right));
    assert(!rez_i32_div_invalid(left, right));
    return rez_i32_from_bits(rez_i64_bits(dividend / divisor));
}

[[maybe_unused]] static int64_t rez_i32_mod(int64_t left, int64_t right) {
    int64_t dividend = rez_i32_from_bits(rez_i64_bits(left));
    int64_t divisor = rez_i32_from_bits(rez_i64_bits(right));
    assert(!rez_i32_div_invalid(left, right));
    return rez_i32_from_bits(rez_i64_bits(dividend % divisor));
}

[[maybe_unused]] static int64_t rez_u32_div(int64_t left, int64_t right) {
    uint64_t dividend = rez_i64_bits(left) & UINT64_C(0xffffffff);
    uint64_t divisor = rez_i64_bits(right) & UINT64_C(0xffffffff);
    assert(!rez_u32_div_invalid(left, right));
    return rez_u32_from_bits(dividend / divisor);
}

[[maybe_unused]] static int64_t rez_u32_mod(int64_t left, int64_t right) {
    uint64_t dividend = rez_i64_bits(left) & UINT64_C(0xffffffff);
    uint64_t divisor = rez_i64_bits(right) & UINT64_C(0xffffffff);
    assert(!rez_u32_div_invalid(left, right));
    return rez_u32_from_bits(dividend % divisor);
}

[[maybe_unused]] static bool rez_shift32_invalid(int64_t shift) {
    return shift < 0 || shift >= 32;
}

[[maybe_unused]] static int64_t rez_i32_shl(int64_t value, int64_t shift) {
    assert(!rez_shift32_invalid(shift));
    return rez_i32_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_u32_shl(int64_t value, int64_t shift) {
    assert(!rez_shift32_invalid(shift));
    return rez_u32_from_bits(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i32_shr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift32_invalid(shift));
    bits = rez_i64_bits(value) & UINT64_C(0xffffffff);
    if (shift == 0) return rez_i32_from_bits(bits);
    if ((bits & UINT64_C(0x80000000)) != 0) bits |= ~UINT64_C(0xffffffff);
    return rez_i32_from_bits(bits >> (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i32_ushr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_shift32_invalid(shift));
    bits = (rez_i64_bits(value) & UINT64_C(0xffffffff)) >> (unsigned)shift;
    return rez_i32_from_bits(bits);
}

[[maybe_unused]] static int64_t rez_u32_ushr(int64_t value, int64_t shift) {
    assert(!rez_shift32_invalid(shift));
    return rez_u32_from_bits((rez_i64_bits(value) & UINT64_C(0xffffffff)) >>
        (unsigned)shift);
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
    assert(result != NULL);
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
    assert(result != NULL);
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
    assert(result != NULL);
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

[[maybe_unused]] static bool rez_i64_div_invalid(int64_t left, int64_t right) {
    return right == 0 || (left == INT64_MIN && right == -1);
}

[[maybe_unused]] static int64_t rez_i64_div(int64_t left, int64_t right) {
    assert(!rez_i64_div_invalid(left, right));
    return left / right;
}

[[maybe_unused]] static int64_t rez_i64_mod(int64_t left, int64_t right) {
    assert(!rez_i64_div_invalid(left, right));
    return left % right;
}

[[maybe_unused]] static bool rez_i64_shift_invalid(int64_t shift) {
    return shift < 0 || shift >= 64;
}

[[maybe_unused]] static int64_t rez_i64_shl(int64_t value, int64_t shift) {
    assert(!rez_i64_shift_invalid(shift));
    return rez_i64_value(rez_i64_bits(value) << (unsigned)shift);
}

[[maybe_unused]] static int64_t rez_i64_shr(int64_t value, int64_t shift) {
    uint64_t bits;
    assert(!rez_i64_shift_invalid(shift));
    if (shift == 0) return value;
    bits = rez_i64_bits(value) >> (unsigned)shift;
    if (value < 0) bits |= ~(uint64_t)0 << (64 - (unsigned)shift);
    return rez_i64_value(bits);
}

[[maybe_unused]] static int64_t rez_i64_ushr(int64_t value, int64_t shift) {
    assert(!rez_i64_shift_invalid(shift));
    return rez_i64_value(rez_i64_bits(value) >> (unsigned)shift);
}

#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
#include <cpuid.h>
#include <smmintrin.h>
#define REZ_CRC32C_X86 1
#define REZ_CRC32C_GNU 1
#elif defined(_M_X64) && defined(_MSC_VER)
#include <intrin.h>
#include <nmmintrin.h>
#define REZ_CRC32C_X86 1
#define REZ_CRC32C_MSVC 1
#else
#define REZ_CRC32C_X86 0
#endif

#if REZ_CRC32C_X86
static int rez_crc32c_hw = -1;
#if REZ_CRC32C_GNU
__attribute__((target("sse4.2")))
#endif
static uint64_t rez_crc32c_u64_x86(uint64_t state, uint64_t word) {
#if REZ_CRC32C_GNU
    return (uint64_t)_mm_crc32_u64((unsigned int)state, (long long)word);
#else
    return (uint64_t)_mm_crc32_u64((unsigned __int64)state, (unsigned __int64)word);
#endif
}
#endif

[[maybe_unused]] static bool rez_crc32c_hardware(void) {
#if REZ_CRC32C_GNU
    if (rez_crc32c_hw < 0) {
        unsigned int eax, ebx, ecx, edx;
        __cpuid(1, eax, ebx, ecx, edx);
        rez_crc32c_hw = (ecx & (1U << 19)) != 0;
    }
    return rez_crc32c_hw != 0;
#elif REZ_CRC32C_MSVC
    if (rez_crc32c_hw < 0) {
        int registers[4];
        __cpuid(registers, 1);
        rez_crc32c_hw = ((unsigned int)registers[2] & (1U << 19)) != 0;
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
