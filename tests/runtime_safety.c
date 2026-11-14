#include <stdint.h>
#include "rez3ext.h"

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

_Alignas(REZ_ALIGNMENT) static char field_arena[64];
_Alignas(REZ_ALIGNMENT) static char proc_arena[64];
_Alignas(REZ_ALIGNMENT) static char slot_arena[64];
_Alignas(REZ_ALIGNMENT) static char exhausted_arena[64];
_Alignas(16) static char misaligned_storage[65];

static int32_t check_generation_exhaustion(void) {
    RezCavity exhausted = {0};
    RezCellMed mediator;
    uint32_t saved;
    void *cell;

    CHECK(rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    cell = rez_cell_z(&exhausted, 8);
    CHECK(cell != nullptr);
    mediator = rez_issue_cell(&exhausted, &exhausted, cell, 8);
    saved = rez_g_gen;

    rez_g_gen = 0;
    rez_decay(&exhausted);
    CHECK(rez_g_gen == 0);
    CHECK(exhausted.generation == 0);
    CHECK(rez_deref_cell(mediator) == nullptr);
    CHECK(!rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    CHECK(rez_deref_cell(mediator) == nullptr);

    rez_g_gen = UINT32_MAX;
    rez_decay(&exhausted);
    CHECK(rez_g_gen == 0);
    CHECK(exhausted.generation == UINT32_MAX);
    CHECK(!rez_frame_reset(&exhausted, nullptr, exhausted_arena, 64));
    rez_g_gen = saved;
    return 0;
}

static bool async_succeed(void *context) {
    (*(int *)context)++;
    return true;
}

static bool async_abort(void *context) {
    (void)context;
    return false;
}

static int check_async_queue(void) {
    RezAsyncQueue queue = {0};
    int completed = 0;
    bool pending = false;
    bool other_pending = false;
    CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &pending));
    CHECK(rez_async_enqueue(&queue, async_abort, &completed, &other_pending));
    CHECK(queue.count == 2);
    CHECK(rez_async_drain(&queue) == 1);
    CHECK(completed == 1);
    CHECK(queue.count == 0);
    CHECK(rez_async_drain(&queue) == 0);
    for (uint32_t i = 0; i < REZ_ASYNC_MAX; i++) {
        bool slot_pending = false;
        CHECK(rez_async_enqueue(&queue, async_succeed, &completed, &slot_pending));
    }
    CHECK(!rez_async_enqueue(&queue, async_succeed, &completed, &pending));
    CHECK(rez_async_drain(&queue) == REZ_ASYNC_MAX);
    return 0;
}

static int32_t check_checked_arithmetic(void) {
    int64_t checked;
    CHECK(!rez_i64_cadd(INT64_MAX, 0, &checked) && checked == INT64_MAX);
    CHECK(rez_i64_cadd(INT64_MAX, 1, &checked));
    CHECK(rez_i64_cadd(INT64_MIN, -1, &checked));
    CHECK(!rez_i64_csub(INT64_MIN, 0, &checked) && checked == INT64_MIN);
    CHECK(rez_i64_csub(INT64_MIN, 1, &checked));
    CHECK(rez_i64_csub(INT64_MAX, -1, &checked));
    CHECK(!rez_i64_cmul(INT64_MIN, 1, &checked) && checked == INT64_MIN);
    CHECK(!rez_i64_cmul(-1, -1, &checked) && checked == 1);
    CHECK(rez_i64_cmul(INT64_MIN, -1, &checked));
    CHECK(rez_i64_cmul(INT64_MAX, 2, &checked));
    return 0;
}

int main(void) {
    RezCavity field = {0};
    RezCavity proc = {0};
    RezCavity slot = {0};
    RezCavity misaligned = {0};
    RezArena empty = {0};
    RezArena misaligned_arena = { .base = misaligned_storage + 1, .cap = 64 };
    RezCellMed med;
    uint32_t gen;
    uint32_t saved;
    void *cell;

    static_assert(REZ3EXT_ABI == 4);
    CHECK(rez_arena_alloc_z(&misaligned_arena, 1) == nullptr);
    CHECK(!rez_frame_reset(&misaligned, nullptr, misaligned_storage + 1, 64));
    CHECK(!misaligned.alive);
    CHECK(misaligned.generation == 0);
    CHECK(rez_frame_reset(&field, nullptr, field_arena, 64));
    CHECK(rez_frame_reset(&proc, &field, proc_arena, 64));
    gen = proc.generation;
    saved = rez_g_gen;
    rez_g_gen = 0;
    CHECK(!rez_frame_reset(&proc, &field, proc_arena, 64));
    CHECK(proc.generation == gen);
    CHECK(proc.alive);
    CHECK(proc.arena.base == proc_arena);
    rez_g_gen = saved;

    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == &slot);
    gen = slot.generation;
    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == nullptr);
    CHECK(slot.generation == gen);
    rez_decay(&slot);
    CHECK(!slot.alive);
    CHECK(slot.arena.base == nullptr);
    CHECK(rez_cav_enter(&slot, nullptr, slot_arena, 64) == &slot);
    CHECK(slot.generation != gen);
    CHECK(slot.arena.base == slot_arena);

    cell = rez_cell_z(&field, 8);
    CHECK(cell != nullptr);
    med = rez_issue_cell(&field, &field, cell, 8);
    CHECK(rez_deref_cell(med) == cell);
    CHECK(rez_cell_bounds(med, 0, 8));
    CHECK(!rez_cell_bounds(med, 1, 8));
    CHECK(!rez_cell_bounds(med, UINT64_MAX, 1));
    CHECK(rez_arena_alloc_z(&empty, 0) == nullptr);
    CHECK(rez_i64_add(INT64_MAX, 1) == INT64_MIN);
    CHECK(rez_i64_sub(INT64_MIN, 1) == INT64_MAX);
    CHECK(rez_i64_shr(-2, 1) == -1);
    CHECK(rez_i64_ushr(-1, 0) == -1);
    CHECK(rez_i64_ushr(-1, 1) == INT64_MAX);
    CHECK(rez_i64_ushr(INT64_MIN, 63) == 1);
    CHECK(rez_i64_shl(1, 63) == INT64_MIN);
    CHECK(rez_i64_div(8, 2) == 4);
    CHECK(rez_i64_mod(8, 3) == 2);
    CHECK(check_checked_arithmetic() == 0);

    rez_decay(&field);
    CHECK(rez_deref_cell(med) == nullptr);
    CHECK(rez_cell_z(&field, 0) == nullptr);
    rez_decay(&proc);
    rez_decay(&slot);
    CHECK(check_async_queue() == 0);
    return check_generation_exhaustion();
}
